/// 硅基流动 TTS 音色管理 Provider
///
/// 实现 TtsVoiceProvider 接口，提供硅基流动的音色管理能力：
/// - 系统预置音色（alex、bella 等）
/// - 用户上传音色
/// - 音色删除
///
/// 2026-01-31: 创建硅基流动 Provider 适配器
library;

import '../siliconflow_tts_service.dart';
import '../tts_config.dart';
import 'tts_voice_provider.dart';

/// 硅基流动 TTS 音色管理 Provider
class SiliconFlowVoiceProvider extends TtsVoiceProvider {
  @override
  String get providerId => 'siliconflow';

  @override
  List<String> get providerAliases => const <String>[
        'siliconflow',
        'silicon_flow',
      ];

  @override
  List<String> get requestFormatAliases => const <String>[
        'siliconflow_indextts',
      ];

  @override
  List<String> get apiHostKeywords => const <String>[
        'siliconflow.cn',
        'siliconflow.com',
        'siliconflow',
      ];

  @override
  String get displayName => '硅基流动';

  @override
  TtsCapabilities get capabilities => const TtsCapabilities(
        hasPresetVoices: true, // 有 alex、bella 等预置音色
        canUploadFile: true, // 支持文件上传
        canUploadUrl: false, // 不支持直接 URL 上传（需要先下载再上传）
        needsPromptText: true, // 需要参考文本
        needsApproval: false, // 不需要审核，立即可用
        hasExpirationPolicy: false, // 无过期策略
        supportsPromptAudio: false, // 不支持示例音频
        supportedFormats: ['mp3', 'wav', 'ogg', 'opus'],
        audioDurationLimit: null, // 无明确限制
        maxAudioSizeBytes: null, // 无明确限制
      );

  @override
  Future<VoiceListResult> listVoices({
    required String apiKey,
    String? targetModel,
  }) async {
    try {
      // 获取预置音色
      final presetVoices = _getPresetVoices();

      // 获取用户音色
      final service = SiliconFlowTtsService(apiKey: apiKey);
      final userVoiceList = await service.getVoiceList();

      final userVoices = userVoiceList.map((voice) {
        return VoicePreset(
          id: 'siliconflow_user_${voice.uri.hashCode}',
          name: voice.customName.isNotEmpty ? voice.customName : '用户音色',
          sourceType: VoiceSourceType.url,
          providerType: VoiceProviderType.siliconFlow,
          source: '硅基流动 · 用户上传',
          promptText: voice.text,
          bindings: [
            VoiceChannelBinding(
              providerId: providerId,
              providerName: displayName,
              adapterId: providerId,
              modelId: voice.model,
              remoteVoiceId: voice.uri,
              sourceKind: VoiceBindingSourceKind.imported,
            ),
          ],
          siliconFlowVoiceUri: voice.uri,
          siliconFlowModel: voice.model,
        );
      }).toList();

      return VoiceListResult(
        presetVoices: presetVoices,
        userVoices: userVoices,
      );
    } on SiliconFlowTtsException catch (e) {
      throw TtsProviderException(
        e.message,
        code: 'SILICONFLOW_ERROR',
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
        '硅基流动只支持文件上传模式',
        code: 'INVALID_REQUEST',
      );
    }

    if (request.promptText == null || request.promptText!.isEmpty) {
      throw TtsProviderException(
        '硅基流动需要提供参考文本',
        code: 'MISSING_PROMPT_TEXT',
      );
    }

    try {
      final service = SiliconFlowTtsService(apiKey: apiKey);
      final result = await service.uploadVoiceFromBytes(
        audioBytes: request.audioBytes!,
        fileName: request.fileName ?? 'audio.mp3',
        customName: request.name,
        text: request.promptText!,
        model: request.targetModel ?? 'IndexTeam/IndexTTS-2',
      );

      final voice = VoicePreset(
        id: 'siliconflow_user_${result.uri.hashCode}',
        name: request.name,
        sourceType: VoiceSourceType.url,
        providerType: VoiceProviderType.siliconFlow,
        source: '硅基流动 · 用户上传',
        promptText: request.promptText,
        bindings: [
          VoiceChannelBinding(
            providerId: providerId,
            providerName: displayName,
            adapterId: providerId,
            modelId: result.model,
            remoteVoiceId: result.uri,
            sourceKind: VoiceBindingSourceKind.remoteCreated,
          ),
        ],
        siliconFlowVoiceUri: result.uri,
        siliconFlowModel: result.model,
      );

      return VoiceCreateResult(
        voice: voice,
        needsApproval: false,
      );
    } on SiliconFlowTtsException catch (e) {
      throw TtsProviderException(
        e.message,
        code: 'SILICONFLOW_ERROR',
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
    // 获取实际的 URI
    String? voiceUri = voice
        ?.resolveBinding(
          providerId: providerId,
          adapterId: providerId,
        )
        ?.remoteVoiceId;
    voiceUri ??= voice?.siliconFlowVoiceUri;

    // 如果没有提供 voice 对象，尝试从 voiceId 解析
    if (voiceUri == null) {
      // 预置音色不能删除
      if (voiceId.startsWith('siliconflow_preset_')) {
        throw TtsProviderException(
          '系统预置音色不能删除',
          code: 'PRESET_VOICE_DELETE_NOT_ALLOWED',
        );
      }
      throw TtsProviderException(
        '无法获取音色 URI，请提供完整的音色信息',
        code: 'MISSING_VOICE_URI',
      );
    }

    try {
      final service = SiliconFlowTtsService(apiKey: apiKey);
      await service.deleteVoice(voiceUri);
    } on SiliconFlowTtsException catch (e) {
      throw TtsProviderException(
        e.message,
        code: 'SILICONFLOW_ERROR',
        originalError: e,
      );
    } catch (e) {
      throw TtsProviderException(
        '删除音色失败: $e',
        originalError: e,
      );
    }
  }

  /// 获取硅基流动的预置音色列表
  @override
  Future<VoicePreset?> queryVoiceStatus({
    required String apiKey,
    required String voiceId,
    VoicePreset? voice,
  }) async {
    return null;
  }

  List<VoicePreset> _getPresetVoices() {
    return SiliconFlowTtsService.presetVoices.map((voice) {
      return VoicePreset(
        id: 'siliconflow_preset_${voice.id}',
        name: voice.name,
        sourceType: VoiceSourceType.preset,
        providerType: VoiceProviderType.siliconFlow,
        source: '硅基流动预置 · ${voice.gender == 'male' ? '男声' : '女声'}',
        bindings: [
          VoiceChannelBinding(
            providerId: providerId,
            providerName: displayName,
            adapterId: providerId,
            modelId: voice.model,
            remoteVoiceId: voice.voiceParam,
            sourceKind: VoiceBindingSourceKind.imported,
          ),
        ],
        siliconFlowVoiceUri: voice.voiceParam, // 格式: model:voiceId
        siliconFlowModel: voice.model,
        isBuiltIn: false, // 预置音色不是内置音色，可以从列表中移除
      );
    }).toList();
  }
}
