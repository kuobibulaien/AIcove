/// TTS 模型测活
///
/// 供应商「测试模型」对语音合成模型走真实合成路径：先从该渠道音色目录挑一个
/// 适配当前模型的音色，再合成一句极短文本。不读写用户的音色预设，也不创建远端音色。
library;

import '../../settings/settings_models.dart';
import 'tts_config.dart';
import 'tts_provider_context.dart';
import 'tts_service.dart';
import 'tts_voice_catalog_service.dart';

class TtsModelProbe {
  const TtsModelProbe._();

  static const String probeText = '你好';

  static Future<String> run({
    required AppSettings settings,
    required ProviderAuth provider,
    required String apiKey,
    required String modelId,
  }) async {
    final resolved = TtsProviderContext.resolveForSelection(
      config: TtsConfig(voicePresets: const []),
      settings: settings,
      providerId: provider.id,
      modelId: modelId,
    );
    final voice = await _pickVoice(
      TtsProviderContext(
        config: resolved.config,
        providerAuth: provider,
        voiceProvider: resolved.voiceProvider,
        apiKey: apiKey,
        requestFormat: resolved.requestFormat,
        selectedModelId: modelId,
      ),
      providerId: provider.id,
      modelId: modelId,
    );
    final remoteVoiceId = voice
        ?.resolveBinding(providerId: provider.id, modelId: modelId)
        ?.remoteVoiceId
        .trim();
    final service = TtsService(
      config: TtsConfig(
        selectedProviderId: provider.id,
        selectedModelId: modelId,
        model: modelId,
        voice: remoteVoiceId?.isNotEmpty == true ? remoteVoiceId : null,
        voicePresets: [?voice],
        selectedVoicePresetId: voice?.id ?? '',
      ),
      apiKey: apiKey,
      requestUrl: provider.apiBaseUrl,
      requestFormat: resolved.requestFormat,
      model: modelId,
      customConfig: provider.customConfig,
    );
    final result = await service.convert(probeText);
    if (!result.success || result.audioUrl.isEmpty) {
      throw TtsException(result.error ?? '未返回音频');
    }
    return voice == null ? '语音合成成功' : '语音合成成功（音色：${voice.name}）';
  }

  /// 目录拿不到时返回 null，让合成走各家适配器的默认音色。
  static Future<VoicePreset?> _pickVoice(
    TtsProviderContext context, {
    required String providerId,
    required String modelId,
  }) async {
    if (!context.hasVoiceProvider) return null;
    final List<VoicePreset> voices;
    try {
      voices = (await TtsVoiceCatalogService.listVoices(context)).allVoices;
    } catch (_) {
      return null;
    }
    for (final voice in voices) {
      if (voice.canUseWithModel(modelId, providerId: providerId)) return voice;
    }
    return voices.isEmpty ? null : voices.first;
  }
}
