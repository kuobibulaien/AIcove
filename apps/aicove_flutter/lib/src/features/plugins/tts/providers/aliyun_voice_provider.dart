/// 阿里云 TTS 音色管理 Provider
///
/// 实现 TtsVoiceProvider 接口，提供阿里云的音色管理能力：
/// - Qwen-TTS：支持 Base64 上传和 URL 上传，立即可用
/// - CosyVoice：只支持 URL 上传，需要审核
///
/// 2026-01-31: 创建阿里云 Provider 适配器
library;

import '../aliyun_voice_clone_service.dart';
import '../tts_config.dart';
import 'tts_voice_provider.dart';

/// 阿里云 Qwen-TTS 音色管理 Provider
class AliyunQwenVoiceProvider extends TtsVoiceProvider {
  @override
  String get providerId => 'aliyun_qwen';

  @override
  List<String> get providerAliases => const <String>[
        'aliyun_qwen',
        'aliyun',
      ];

  @override
  List<String> get requestFormatAliases => const <String>[
        'aliyun_qwen_tts',
      ];

  @override
  List<String> get apiHostKeywords => const <String>[
        'dashscope.aliyuncs.com',
        'dashscope',
        'aliyuncs',
      ];

  @override
  String get displayName => '阿里云 Qwen-TTS';

  @override
  TtsCapabilities get capabilities => const TtsCapabilities(
        hasPresetVoices: false, // 无预置音色
        canUploadFile: true, // 支持文件上传（Base64）
        canUploadUrl: true, // 支持 URL 上传
        needsPromptText: false, // 参考文本可选
        needsApproval: false, // 不需要审核，立即可用
        hasExpirationPolicy: false, // 无过期策略
        supportsPromptAudio: false, // 不支持示例音频
        supportedFormats: ['mp3', 'wav', 'm4a', 'ogg'],
        audioDurationLimit: null, // 无明确限制
        maxAudioSizeBytes: 10 * 1024 * 1024, // 10MB
      );

  @override
  Future<VoiceListResult> listVoices({
    required String apiKey,
    String? targetModel,
  }) async {
    try {
      final service = AliyunVoiceCloneService(apiKey: apiKey);
      final qwenVoices = await service.listQwenVoices(pageSize: 100);

      final userVoices = qwenVoices.map((voice) {
        return VoicePreset(
          id: 'aliyun_qwen_${voice.voiceId.hashCode}',
          name: _extractVoiceName(voice.voiceId),
          sourceType: VoiceSourceType.preset,
          providerType: VoiceProviderType.aliyun,
          source: '已创建 Qwen-TTS 音色 · ${voice.gmtCreate ?? ""}',
          aliyunVoiceId: voice.voiceId,
          aliyunTargetModel: voice.targetModel,
          aliyunVoiceStatus: 'OK', // Qwen-TTS 音色创建后即可用
        );
      }).toList();

      return VoiceListResult(
        presetVoices: const [],
        userVoices: userVoices,
      );
    } on VoiceCloneException catch (e) {
      throw TtsProviderException(
        e.message,
        code: 'ALIYUN_ERROR',
        originalError: e,
      );
    } catch (e) {
      throw TtsProviderException(
        '获取音色列表失败: $e',
        originalError: e,
      );
    }
  }

  @override
  Future<VoiceCreateResult> createVoice({
    required String apiKey,
    required VoiceCreateRequest request,
  }) async {
    try {
      final service = AliyunVoiceCloneService(apiKey: apiKey);
      final targetModel =
          request.targetModel ?? 'qwen3-tts-vc-realtime-2026-01-15';

      QwenVoiceCreateResult result;

      if (request.isFileUpload) {
        // 文件上传模式
        final mimeType = _getMimeType(request.fileName ?? 'audio.mp3');
        result = await service.createQwenVoiceFromBytes(
          audioBytes: request.audioBytes!,
          mimeType: mimeType,
          preferredName: _sanitizeName(request.name),
          targetModel: targetModel,
          promptText: request.promptText,
          language: request.language,
        );
      } else if (request.isUrlUpload) {
        // URL 上传模式
        result = await service.createQwenVoiceFromUrl(
          audioUrl: request.audioUrl!,
          preferredName: _sanitizeName(request.name),
          targetModel: targetModel,
          promptText: request.promptText,
          language: request.language,
        );
      } else {
        throw TtsProviderException(
          '需要提供音频文件或 URL',
          code: 'MISSING_AUDIO',
        );
      }

      final voice = VoicePreset(
        id: 'aliyun_qwen_${result.voiceId.hashCode}',
        name: request.name,
        sourceType: VoiceSourceType.url,
        providerType: VoiceProviderType.aliyun,
        source: '阿里云 Qwen-TTS',
        promptAudioUrl: request.audioUrl,
        promptText: request.promptText,
        aliyunVoiceId: result.voiceId,
        aliyunTargetModel: result.targetModel,
        aliyunVoiceStatus: 'OK',
      );

      return VoiceCreateResult(
        voice: voice,
        needsApproval: false,
      );
    } on VoiceCloneException catch (e) {
      throw TtsProviderException(
        e.message,
        code: 'ALIYUN_ERROR',
        originalError: e,
      );
    } catch (e) {
      throw TtsProviderException(
        '创建音色失败: $e',
        originalError: e,
      );
    }
  }

  @override
  Future<void> deleteVoice({
    required String apiKey,
    required String voiceId,
    VoicePreset? voice,
  }) async {
    // 获取实际的阿里云 voice ID
    String? aliyunVoiceId = voice?.aliyunVoiceId;

    if (aliyunVoiceId == null || aliyunVoiceId.isEmpty) {
      throw TtsProviderException(
        '无法获取阿里云音色 ID',
        code: 'MISSING_VOICE_ID',
      );
    }

    try {
      final service = AliyunVoiceCloneService(apiKey: apiKey);
      await service.deleteQwenVoice(aliyunVoiceId);
    } on VoiceCloneException catch (e) {
      throw TtsProviderException(
        e.message,
        code: 'ALIYUN_ERROR',
        originalError: e,
      );
    } catch (e) {
      throw TtsProviderException(
        '删除音色失败: $e',
        originalError: e,
      );
    }
  }

  /// 从 voice ID 中提取显示名称
  @override
  Future<VoicePreset?> queryVoiceStatus({
    required String apiKey,
    required String voiceId,
    VoicePreset? voice,
  }) async {
    return null;
  }

  String _extractVoiceName(String voiceId) {
    // voice ID 格式可能是: prefix_timestamp 或纯 ID
    final parts = voiceId.split('_');
    if (parts.length > 1) {
      return parts.first;
    }
    return voiceId.length > 10 ? '${voiceId.substring(0, 10)}...' : voiceId;
  }

  /// 清理名称
  String _sanitizeName(String name) {
    var sanitized = name.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '');
    if (sanitized.isEmpty) sanitized = 'voice';
    if (sanitized.length > 16) sanitized = sanitized.substring(0, 16);
    return sanitized;
  }

  /// 获取 MIME 类型
  String _getMimeType(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    switch (ext) {
      case 'wav':
        return 'audio/wav';
      case 'mp3':
        return 'audio/mpeg';
      case 'm4a':
        return 'audio/mp4';
      case 'ogg':
        return 'audio/ogg';
      default:
        return 'audio/mpeg';
    }
  }
}

/// 阿里云 CosyVoice 音色管理 Provider
class AliyunCosyVoiceProvider extends TtsVoiceProvider {
  @override
  String get providerId => 'aliyun_cosyvoice';

  @override
  List<String> get providerAliases => const <String>[
        'aliyun_cosyvoice',
      ];

  @override
  List<String> get requestFormatAliases => const <String>[
        'aliyun_cosyvoice',
      ];

  @override
  String get displayName => '阿里云 CosyVoice';

  @override
  TtsCapabilities get capabilities => const TtsCapabilities(
        hasPresetVoices: false, // 无预置音色
        canUploadFile: false, // 不支持直接文件上传
        canUploadUrl: true, // 只支持 URL 上传
        needsPromptText: false, // 不需要参考文本
        needsApproval: true, // 需要审核
        hasExpirationPolicy: false, // 无过期策略
        supportsPromptAudio: false, // 不支持示例音频
        supportedFormats: ['mp3', 'wav', 'm4a', 'ogg'],
        audioDurationLimit: null,
        maxAudioSizeBytes: 10 * 1024 * 1024, // 10MB
      );

  @override
  Future<VoiceListResult> listVoices({
    required String apiKey,
    String? targetModel,
  }) async {
    try {
      final service = AliyunVoiceCloneService(apiKey: apiKey);
      final cosyVoices = await service.listCosyVoices(pageSize: 100);

      final userVoices = cosyVoices.map((voice) {
        return VoicePreset(
          id: 'aliyun_cosy_${voice.voiceId.hashCode}',
          name: _extractVoiceName(voice.voiceId),
          sourceType: VoiceSourceType.preset,
          providerType: VoiceProviderType.aliyun,
          source: '阿里云 CosyVoice · ${voice.status}',
          aliyunVoiceId: voice.voiceId,
          aliyunTargetModel: voice.targetModel,
          aliyunVoiceStatus: voice.status,
        );
      }).toList();

      return VoiceListResult(
        presetVoices: const [],
        userVoices: userVoices,
      );
    } on VoiceCloneException catch (e) {
      throw TtsProviderException(
        e.message,
        code: 'ALIYUN_ERROR',
        originalError: e,
      );
    } catch (e) {
      throw TtsProviderException(
        '获取音色列表失败: $e',
        originalError: e,
      );
    }
  }

  @override
  Future<VoiceCreateResult> createVoice({
    required String apiKey,
    required VoiceCreateRequest request,
  }) async {
    if (!request.isUrlUpload) {
      throw TtsProviderException(
        'CosyVoice 只支持 URL 上传模式',
        code: 'INVALID_REQUEST',
      );
    }

    try {
      final service = AliyunVoiceCloneService(apiKey: apiKey);
      final targetModel = request.targetModel ?? 'cosyvoice-v3-plus';

      final result = await service.createCosyVoice(
        audioUrl: request.audioUrl!,
        prefix: _sanitizeName(request.name),
        targetModel: targetModel,
      );

      final voice = VoicePreset(
        id: 'aliyun_cosy_${result.voiceId.hashCode}',
        name: request.name,
        sourceType: VoiceSourceType.url,
        providerType: VoiceProviderType.aliyun,
        source: '阿里云 CosyVoice',
        promptAudioUrl: request.audioUrl,
        aliyunVoiceId: result.voiceId,
        aliyunTargetModel: result.targetModel,
        aliyunVoiceStatus: result.status, // DEPLOYING
      );

      return VoiceCreateResult(
        voice: voice,
        needsApproval: true,
        statusMessage: '音色正在审核中，请稍候...',
      );
    } on VoiceCloneException catch (e) {
      throw TtsProviderException(
        e.message,
        code: 'ALIYUN_ERROR',
        originalError: e,
      );
    } catch (e) {
      throw TtsProviderException(
        '创建音色失败: $e',
        originalError: e,
      );
    }
  }

  @override
  Future<void> deleteVoice({
    required String apiKey,
    required String voiceId,
    VoicePreset? voice,
  }) async {
    String? aliyunVoiceId = voice?.aliyunVoiceId;

    if (aliyunVoiceId == null || aliyunVoiceId.isEmpty) {
      throw TtsProviderException(
        '无法获取阿里云音色 ID',
        code: 'MISSING_VOICE_ID',
      );
    }

    try {
      final service = AliyunVoiceCloneService(apiKey: apiKey);
      await service.deleteCosyVoice(aliyunVoiceId);
    } on VoiceCloneException catch (e) {
      throw TtsProviderException(
        e.message,
        code: 'ALIYUN_ERROR',
        originalError: e,
      );
    } catch (e) {
      throw TtsProviderException(
        '删除音色失败: $e',
        originalError: e,
      );
    }
  }

  @override
  Future<VoicePreset?> queryVoiceStatus({
    required String apiKey,
    required String voiceId,
    VoicePreset? voice,
  }) async {
    String? aliyunVoiceId = voice?.aliyunVoiceId;

    if (aliyunVoiceId == null || aliyunVoiceId.isEmpty) {
      return null;
    }

    try {
      final service = AliyunVoiceCloneService(apiKey: apiKey);
      final info = await service.queryCosyVoice(aliyunVoiceId);

      // 返回更新后的音色
      return voice?.copyWith(
        aliyunVoiceStatus: info.status,
        source: '阿里云 CosyVoice · ${info.status}',
      );
    } catch (e) {
      // 查询失败时返回 null
      return null;
    }
  }

  /// 从 voice ID 中提取显示名称
  String _extractVoiceName(String voiceId) {
    final parts = voiceId.split('_');
    if (parts.length > 1) {
      return parts.first;
    }
    return voiceId.length > 10 ? '${voiceId.substring(0, 10)}...' : voiceId;
  }

  /// 清理名称
  String _sanitizeName(String name) {
    var sanitized = name.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
    if (sanitized.isEmpty) sanitized = 'voice';
    if (sanitized.length > 10) sanitized = sanitized.substring(0, 10);
    return sanitized;
  }
}
