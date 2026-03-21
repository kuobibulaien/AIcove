/// TTS 音色目录服务
///
/// 统一收口远端音色的列出、创建、删除与状态查询。
library;

import 'providers/tts_voice_provider.dart';
import 'tts_config.dart';
import 'tts_provider_context.dart';

class TtsVoiceCatalogService {
  static Future<VoiceListResult> listVoices(
    TtsProviderContext context, {
    String? targetModel,
  }) async {
    final provider = _requireProvider(context);
    final apiKey = _requireApiKey(context);
    return provider.listVoices(
      apiKey: apiKey,
      targetModel: targetModel ?? context.selectedModelId,
    );
  }

  static Future<VoiceCreateResult> createVoice({
    required TtsProviderContext context,
    required VoiceCreateRequest request,
    String? targetModel,
  }) async {
    final provider = _requireProvider(context);
    final apiKey = _requireApiKey(context);
    final effectiveModel =
        targetModel ?? request.targetModel ?? context.selectedModelId;
    return provider.createVoice(
      apiKey: apiKey,
      request: VoiceCreateRequest(
        name: request.name,
        audioBytes: request.audioBytes,
        fileName: request.fileName,
        audioUrl: request.audioUrl,
        promptText: request.promptText,
        targetModel: effectiveModel,
        promptAudioBytes: request.promptAudioBytes,
        promptAudioUrl: request.promptAudioUrl,
        language: request.language,
        customVoiceId: request.customVoiceId,
      ),
    );
  }

  static Future<void> deleteVoice({
    required TtsProviderContext context,
    required String voiceId,
    VoicePreset? voice,
  }) async {
    final provider = _requireProvider(context);
    final apiKey = _requireApiKey(context);
    await provider.deleteVoice(
      apiKey: apiKey,
      voiceId: voiceId,
      voice: voice,
    );
  }

  static Future<VoicePreset?> queryVoiceStatus({
    required TtsProviderContext context,
    required String voiceId,
    VoicePreset? voice,
  }) async {
    final provider = _requireProvider(context);
    final apiKey = _requireApiKey(context);
    return provider.queryVoiceStatus(
      apiKey: apiKey,
      voiceId: voiceId,
      voice: voice,
    );
  }

  static TtsVoiceProvider _requireProvider(TtsProviderContext context) {
    final provider = context.voiceProvider;
    if (provider == null) {
      throw TtsProviderException('当前渠道暂无可用的 TTS 音色适配器');
    }
    return provider;
  }

  static String _requireApiKey(TtsProviderContext context) {
    final apiKey = context.apiKey?.trim();
    if (apiKey == null || apiKey.isEmpty) {
      throw TtsProviderException('当前渠道未配置 API Key');
    }
    return apiKey;
  }
}
