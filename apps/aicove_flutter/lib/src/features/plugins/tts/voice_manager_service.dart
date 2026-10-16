/// TTS 音色管理服务
///
/// 统一管理不同渠道商的音色：
/// - 获取渠道商的预置音色列表
/// - 获取用户已上传的音色列表
/// - 上传音色到渠道商
///
/// 2026-01-27: 创建音色管理服务
library;

import '../../../core/app_logger.dart';
import '../../settings/app_settings.dart';
import 'tts_config.dart';
import 'aliyun_voice_clone_service.dart';

/// 音色管理服务
class VoiceManagerService {
  /// 创建阿里云音色（从公网 URL）
  static Future<VoicePreset> createAliyunVoiceFromUrl({
    required String apiKey,
    required String audioUrl,
    required String voiceName,
    required String targetModel,
    String? promptText,
  }) async {
    try {
      final service = AliyunVoiceCloneService(apiKey: apiKey);
      final isCosyVoice = targetModel.contains('cosyvoice');

      String voiceId;
      String? voiceStatus;

      if (isCosyVoice) {
        // CosyVoice 需要创建音色
        final result = await service.createCosyVoice(
          audioUrl: audioUrl,
          prefix: _sanitizeVoiceName(voiceName),
          targetModel: targetModel,
        );
        voiceId = result.voiceId;
        voiceStatus = result.status;
      } else {
        // Qwen-TTS 创建音色
        final result = await service.createQwenVoiceFromUrl(
          audioUrl: audioUrl,
          preferredName: _sanitizeVoiceName(voiceName),
          targetModel: targetModel,
          promptText: promptText,
        );
        voiceId = result.voiceId;
        voiceStatus = 'OK';
      }

      return VoicePreset(
        id: 'aliyun_${voiceId.hashCode}',
        name: voiceName,
        sourceType: VoiceSourceType.url,
        providerType: VoiceProviderType.aliyun,
        source: '声音复刻 · ${isCosyVoice ? 'CosyVoice' : 'Qwen-TTS'}',
        promptAudioUrl: audioUrl,
        promptText: promptText,
        aliyunVoiceId: voiceId,
        aliyunTargetModel: targetModel,
        aliyunVoiceStatus: voiceStatus,
      );
    } catch (e) {
      AppLogger.error('VoiceManager', '创建阿里云音色失败', metadata: {'error': e.toString()});
      rethrow;
    }
  }

  /// 为已有音色创建阿里云音色 ID
  static Future<VoicePreset> createAliyunVoiceForPreset({
    required String apiKey,
    required VoicePreset preset,
    required String targetModel,
  }) async {
    if (preset.promptAudioUrl == null || preset.promptAudioUrl!.isEmpty) {
      throw ArgumentError('音色缺少参考音频 URL');
    }

    final result = await createAliyunVoiceFromUrl(
      apiKey: apiKey,
      audioUrl: preset.promptAudioUrl!,
      voiceName: preset.name,
      targetModel: targetModel,
      promptText: preset.promptText,
    );

    // 合并到现有音色
    return preset.copyWith(
      aliyunVoiceId: result.aliyunVoiceId,
      aliyunTargetModel: result.aliyunTargetModel,
      aliyunVoiceStatus: result.aliyunVoiceStatus,
    );
  }

  /// 获取渠道的 TTS API Key
  static String? getProviderApiKey(List<ProviderAuth> providers, String providerId) {
    final provider = providers.where((p) => p.id == providerId).firstOrNull;
    if (provider == null || provider.apiKeys.isEmpty) return null;
    return provider.apiKeys.first;
  }

  /// 判断渠道是否为阿里云
  static bool isAliyunProvider(ProviderAuth provider) {
    final url = provider.apiBaseUrl.toLowerCase();
    final format = provider.customConfig['requestFormat'] as String?;
    return url.contains('dashscope') ||
           url.contains('aliyuncs') ||
           format == 'aliyun' ||
           format == 'aliyun_cosyvoice' ||
           format == 'aliyun_qwen_tts';
  }

  /// 判断模型是否为阿里云模型
  static bool isAliyunModel(String modelId) {
    return modelId.contains('cosyvoice') || modelId.contains('qwen');
  }

  /// 清理音色名称（用于 API）
  static String _sanitizeVoiceName(String name) {
    var sanitized = name.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '');
    if (sanitized.isEmpty) sanitized = 'voice';
    if (sanitized.length > 10) sanitized = sanitized.substring(0, 10);
    return sanitized.toLowerCase();
  }
}
