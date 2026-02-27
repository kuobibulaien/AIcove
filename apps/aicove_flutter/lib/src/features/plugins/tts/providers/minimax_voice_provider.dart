/// MiniMax TTS 音色管理 Provider
///
/// 实现 TtsVoiceProvider 接口，提供 MiniMax 的音色管理能力：
/// - 系统预置音色
/// - 用户复刻音色（两步流程：上传 → 复刻）
/// - 7天临时音色过期策略
///
/// 2026-01-31: 创建 MiniMax Provider 适配器
library;

import '../minimax_tts_service.dart';
import '../tts_config.dart';
import 'tts_voice_provider.dart';

/// MiniMax TTS 音色管理 Provider
class MinimaxVoiceProvider implements TtsVoiceProvider {
  @override
  String get providerId => 'minimax';

  @override
  String get displayName => 'MiniMax';

  @override
  TtsCapabilities get capabilities => const TtsCapabilities(
        hasPresetVoices: true, // 有系统预置音色
        canUploadFile: true, // 支持文件上传
        canUploadUrl: false, // 不支持直接 URL 上传
        needsPromptText: false, // 参考文本可选（用于增强效果）
        needsApproval: false, // 不需要审核，立即可用
        hasExpirationPolicy: true, // 有7天临时音色策略
        expirationDescription: '复刻音色为临时音色，7天内需使用一次才能永久保留',
        supportsPromptAudio: true, // 支持示例音频增强效果
        supportedFormats: ['mp3', 'm4a', 'wav'],
        audioDurationLimit: '10秒-5分钟',
        maxAudioSizeBytes: 20 * 1024 * 1024, // 20MB
      );

  @override
  Future<VoiceListResult> listVoices({
    required String apiKey,
    String? targetModel,
  }) async {
    try {
      final service = MinimaxTtsService(apiKey: apiKey);
      final result = await service.getVoiceList();

      // 转换系统音色
      final presetVoices = result.systemVoices.map((voice) {
        return VoicePreset(
          id: 'minimax_system_${voice.voiceId}',
          name: voice.name ?? voice.voiceId,
          sourceType: VoiceSourceType.preset,
          providerType: VoiceProviderType.custom, // MiniMax 暂无专门的枚举
          source: '${voice.description ?? "MiniMax 系统音色"}',
          isBuiltIn: false,
        )..setMinimaxVoiceId(voice.voiceId);
      }).toList();

      // 转换复刻音色
      final userVoices = result.clonedVoices.map((voice) {
        return VoicePreset(
          id: 'minimax_cloned_${voice.voiceId}',
          name: voice.name ?? voice.voiceId,
          sourceType: VoiceSourceType.url,
          providerType: VoiceProviderType.custom,
          source: 'MiniMax 复刻音色 · ${voice.createdTime ?? ""}',
        )..setMinimaxVoiceId(voice.voiceId);
      }).toList();

      return VoiceListResult(
        presetVoices: presetVoices,
        userVoices: userVoices,
      );
    } on MinimaxTtsException catch (e) {
      throw TtsProviderException(
        e.message,
        code: 'MINIMAX_ERROR',
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
    if (!request.isFileUpload) {
      throw TtsProviderException(
        'MiniMax 只支持文件上传模式',
        code: 'INVALID_REQUEST',
      );
    }

    // 生成 voice_id（如果未提供）
    final voiceId = request.customVoiceId ?? _generateVoiceId(request.name);

    try {
      final service = MinimaxTtsService(apiKey: apiKey);

      // 1. 上传复刻音频
      final fileId = await service.uploadCloneAudio(
        audioBytes: request.audioBytes!,
        fileName: request.fileName ?? 'audio.mp3',
      );

      // 2. 上传示例音频（可选）
      int? promptFileId;
      if (request.promptAudioBytes != null &&
          request.promptAudioBytes!.isNotEmpty) {
        promptFileId = await service.uploadPromptAudio(
          audioBytes: request.promptAudioBytes!,
          fileName: 'prompt.mp3',
        );
      }

      // 3. 调用复刻接口
      final result = await service.cloneVoice(
        fileId: fileId,
        voiceId: voiceId,
        promptAudioFileId: promptFileId,
        promptText: request.promptText,
        testText: null, // 不需要试听
        model: request.targetModel,
      );

      final voice = VoicePreset(
        id: 'minimax_cloned_${result.voiceId}',
        name: request.name,
        sourceType: VoiceSourceType.url,
        providerType: VoiceProviderType.custom,
        source: 'MiniMax 复刻',
        promptText: request.promptText,
      )..setMinimaxVoiceId(result.voiceId);

      return VoiceCreateResult(
        voice: voice,
        needsApproval: false,
        statusMessage: '音色复刻成功！注意：7天内需使用一次才能永久保留',
      );
    } on MinimaxTtsException catch (e) {
      throw TtsProviderException(
        e.message,
        code: 'MINIMAX_ERROR',
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
    // 从 voice 中获取 MiniMax voice_id
    String? minimaxVoiceId = voice?.getMinimaxVoiceId();

    // 如果是系统音色，不能删除
    if (voiceId.startsWith('minimax_system_')) {
      throw TtsProviderException(
        '系统音色不能删除',
        code: 'SYSTEM_VOICE_DELETE_NOT_ALLOWED',
      );
    }

    if (minimaxVoiceId == null || minimaxVoiceId.isEmpty) {
      // 尝试从 voiceId 解析
      if (voiceId.startsWith('minimax_cloned_')) {
        minimaxVoiceId = voiceId.substring('minimax_cloned_'.length);
      } else {
        throw TtsProviderException(
          '无法获取 MiniMax 音色 ID',
          code: 'MISSING_VOICE_ID',
        );
      }
    }

    try {
      final service = MinimaxTtsService(apiKey: apiKey);
      await service.deleteVoice(minimaxVoiceId);
    } on MinimaxTtsException catch (e) {
      throw TtsProviderException(
        e.message,
        code: 'MINIMAX_ERROR',
        originalError: e,
      );
    } catch (e) {
      throw TtsProviderException(
        '删除音色失败: $e',
        originalError: e,
      );
    }
  }

  /// 生成符合 MiniMax 要求的 voice_id
  /// 规则：8-256字符，字母开头
  @override
  Future<VoicePreset?> queryVoiceStatus({
    required String apiKey,
    required String voiceId,
    VoicePreset? voice,
  }) async {
    return null;
  }

  String _generateVoiceId(String name) {
    // 移除非字母数字字符
    var sanitized = name.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');

    // 确保以字母开头
    if (sanitized.isEmpty || !RegExp(r'^[a-zA-Z]').hasMatch(sanitized)) {
      sanitized = 'Voice$sanitized';
    }

    // 确保至少8个字符
    if (sanitized.length < 8) {
      sanitized = sanitized + DateTime.now().millisecondsSinceEpoch.toString();
    }

    // 限制长度
    if (sanitized.length > 256) {
      sanitized = sanitized.substring(0, 256);
    }

    return sanitized;
  }
}

/// VoicePreset 扩展，用于存储 MiniMax 特定的 voice_id
extension MinimaxVoicePresetExtension on VoicePreset {
  static final _minimaxVoiceIds = <String, String>{};

  /// 设置 MiniMax voice_id
  void setMinimaxVoiceId(String voiceId) {
    _minimaxVoiceIds[id] = voiceId;
  }

  /// 获取 MiniMax voice_id
  String? getMinimaxVoiceId() {
    return _minimaxVoiceIds[id];
  }
}
