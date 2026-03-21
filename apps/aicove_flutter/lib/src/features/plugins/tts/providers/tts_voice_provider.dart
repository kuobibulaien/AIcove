/// TTS 音色管理统一抽象接口
///
/// 提供统一的音色管理接口，让不同 TTS 渠道商（硅基流动、阿里云、MiniMax 等）
/// 可以用相同的方式进行音色的获取、创建、删除操作。
///
/// 设计原则：
/// - 输入输出统一使用 VoicePreset（现有类，保持兼容）
/// - 各渠道的特殊参数通过 VoicePreset 的扩展字段存储
/// - 通过 TtsCapabilities 描述渠道能力，让 UI 自适应
///
/// 2026-01-31: 创建统一 TTS Provider 抽象层
library;

import 'dart:typed_data';

import '../tts_config.dart';

String _normalizeRoutingValue(String? value) {
  return value?.trim().toLowerCase() ?? '';
}

/// TTS 渠道能力描述
///
/// 用于告诉 UI 该渠道支持哪些功能，UI 根据此信息动态显示/隐藏相关控件
class TtsCapabilities {
  /// 是否有系统预置音色（如硅基流动的 alex、bella 等）
  final bool hasPresetVoices;

  /// 是否支持文件上传创建音色
  final bool canUploadFile;

  /// 是否支持通过 URL 创建音色
  final bool canUploadUrl;

  /// 创建音色时是否需要参考文本
  final bool needsPromptText;

  /// 创建后是否需要审核（如阿里云 CosyVoice）
  final bool needsApproval;

  /// 是否有过期策略（如 MiniMax 7天临时音色）
  final bool hasExpirationPolicy;

  /// 过期时间描述（如 "7天内需使用一次"）
  final String? expirationDescription;

  /// 是否支持示例音频（增强复刻效果）
  final bool supportsPromptAudio;

  /// 支持的音频格式列表
  final List<String> supportedFormats;

  /// 音频时长限制描述（如 "10秒-5分钟"）
  final String? audioDurationLimit;

  /// 音频大小限制（字节）
  final int? maxAudioSizeBytes;

  const TtsCapabilities({
    this.hasPresetVoices = false,
    this.canUploadFile = true,
    this.canUploadUrl = true,
    this.needsPromptText = false,
    this.needsApproval = false,
    this.hasExpirationPolicy = false,
    this.expirationDescription,
    this.supportsPromptAudio = false,
    this.supportedFormats = const ['mp3', 'wav', 'm4a'],
    this.audioDurationLimit,
    this.maxAudioSizeBytes,
  });

  /// 复制并修改
  TtsCapabilities copyWith({
    bool? hasPresetVoices,
    bool? canUploadFile,
    bool? canUploadUrl,
    bool? needsPromptText,
    bool? needsApproval,
    bool? hasExpirationPolicy,
    String? expirationDescription,
    bool? supportsPromptAudio,
    List<String>? supportedFormats,
    String? audioDurationLimit,
    int? maxAudioSizeBytes,
  }) {
    return TtsCapabilities(
      hasPresetVoices: hasPresetVoices ?? this.hasPresetVoices,
      canUploadFile: canUploadFile ?? this.canUploadFile,
      canUploadUrl: canUploadUrl ?? this.canUploadUrl,
      needsPromptText: needsPromptText ?? this.needsPromptText,
      needsApproval: needsApproval ?? this.needsApproval,
      hasExpirationPolicy: hasExpirationPolicy ?? this.hasExpirationPolicy,
      expirationDescription:
          expirationDescription ?? this.expirationDescription,
      supportsPromptAudio: supportsPromptAudio ?? this.supportsPromptAudio,
      supportedFormats: supportedFormats ?? this.supportedFormats,
      audioDurationLimit: audioDurationLimit ?? this.audioDurationLimit,
      maxAudioSizeBytes: maxAudioSizeBytes ?? this.maxAudioSizeBytes,
    );
  }
}

/// 创建音色请求
///
/// 统一的音色创建请求参数，各渠道根据自身能力使用其中的字段
class VoiceCreateRequest {
  /// 音色名称
  final String name;

  /// 音频二进制数据（文件上传模式）
  final Uint8List? audioBytes;

  /// 音频文件名（用于确定 MIME 类型）
  final String? fileName;

  /// 音频 URL（URL 上传模式）
  final String? audioUrl;

  /// 参考文本（与音频内容对应）
  final String? promptText;

  /// 目标模型（如 qwen3-tts-vc-realtime、IndexTeam/IndexTTS-2）
  final String? targetModel;

  /// 示例音频二进制（MiniMax 用于增强效果）
  final Uint8List? promptAudioBytes;

  /// 示例音频 URL
  final String? promptAudioUrl;

  /// 语言提示（如 zh、en）
  final String? language;

  /// 自定义 voice_id（MiniMax 支持用户自定义）
  final String? customVoiceId;

  const VoiceCreateRequest({
    required this.name,
    this.audioBytes,
    this.fileName,
    this.audioUrl,
    this.promptText,
    this.targetModel,
    this.promptAudioBytes,
    this.promptAudioUrl,
    this.language,
    this.customVoiceId,
  });

  /// 是否使用文件上传模式
  bool get isFileUpload => audioBytes != null && audioBytes!.isNotEmpty;

  /// 是否使用 URL 上传模式
  bool get isUrlUpload => audioUrl != null && audioUrl!.isNotEmpty;
}

/// 音色创建结果
class VoiceCreateResult {
  /// 创建的音色预设
  final VoicePreset voice;

  /// 是否需要等待审核
  final bool needsApproval;

  /// 审核状态描述（如 "审核中，请稍候"）
  final String? statusMessage;

  const VoiceCreateResult({
    required this.voice,
    this.needsApproval = false,
    this.statusMessage,
  });
}

/// 音色列表结果
class VoiceListResult {
  /// 预置音色列表（系统提供的固定音色）
  final List<VoicePreset> presetVoices;

  /// 用户音色列表（用户上传/创建的音色）
  final List<VoicePreset> userVoices;

  const VoiceListResult({
    this.presetVoices = const [],
    this.userVoices = const [],
  });

  /// 所有音色
  List<VoicePreset> get allVoices => [...presetVoices, ...userVoices];

  /// 音色总数
  int get totalCount => presetVoices.length + userVoices.length;
}

/// TTS 厂商识别元数据骨架
///
/// 用于统一 providerId / requestFormat / apiUrl 的识别规则。
/// 第一版只承载路由元数据，不介入真实 API 调用逻辑。
abstract class TtsVendorAdapter {
  /// 厂商主标识。
  String get providerId;

  /// 厂商别名，用于匹配显式 providerId。
  List<String> get providerAliases => <String>[providerId];

  /// 厂商支持的 requestFormat 别名。
  List<String> get requestFormatAliases => const <String>[];

  /// API 地址识别关键字。
  List<String> get apiHostKeywords => const <String>[];

  bool matchesProviderId(String? rawProviderId) {
    final normalized = _normalizeRoutingValue(rawProviderId);
    if (normalized.isEmpty) return false;
    for (final alias in providerAliases) {
      if (_normalizeRoutingValue(alias) == normalized) {
        return true;
      }
    }
    return false;
  }

  bool matchesRequestFormat(String? rawRequestFormat) {
    final normalized = _normalizeRoutingValue(rawRequestFormat);
    if (normalized.isEmpty) return false;
    for (final alias in requestFormatAliases) {
      if (_normalizeRoutingValue(alias) == normalized) {
        return true;
      }
    }
    return false;
  }

  bool matchesApiUrl(String? rawApiUrl) {
    final normalizedUrl = _normalizeRoutingValue(rawApiUrl);
    if (normalizedUrl.isEmpty) return false;

    final parsedUri = Uri.tryParse(rawApiUrl?.trim() ?? '');
    final normalizedHost = _normalizeRoutingValue(parsedUri?.host);

    for (final keyword in apiHostKeywords) {
      final normalizedKeyword = _normalizeRoutingValue(keyword);
      if (normalizedKeyword.isEmpty) continue;
      if (normalizedHost == normalizedKeyword ||
          normalizedHost.endsWith('.$normalizedKeyword') ||
          normalizedUrl.contains(normalizedKeyword)) {
        return true;
      }
    }
    return false;
  }
}

/// TTS 音色管理 Provider 抽象接口
///
/// 各 TTS 渠道商需要实现此接口，提供统一的音色管理能力
abstract class TtsVoiceProvider extends TtsVendorAdapter {
  /// 渠道标识（如 'siliconflow'、'aliyun_qwen'、'minimax'）
  @override
  String get providerId;

  /// 渠道显示名称（如 '硅基流动'、'阿里云'、'MiniMax'）
  String get displayName;

  /// 渠道能力描述
  TtsCapabilities get capabilities;

  /// 获取所有可用音色（预置 + 用户）
  ///
  /// [apiKey] API 密钥
  /// [targetModel] 可选，筛选特定模型的音色
  Future<VoiceListResult> listVoices({
    required String apiKey,
    String? targetModel,
  });

  /// 创建/上传音色
  ///
  /// [apiKey] API 密钥
  /// [request] 创建请求参数
  Future<VoiceCreateResult> createVoice({
    required String apiKey,
    required VoiceCreateRequest request,
  });

  /// 删除音色
  ///
  /// [apiKey] API 密钥
  /// [voiceId] 音色 ID（VoicePreset.id 或渠道特定的 ID）
  /// [voice] 可选，完整的音色信息（用于获取渠道特定的 ID）
  Future<void> deleteVoice({
    required String apiKey,
    required String voiceId,
    VoicePreset? voice,
  });

  /// 查询音色状态（用于需要审核的渠道）
  ///
  /// [apiKey] API 密钥
  /// [voiceId] 音色 ID
  /// 返回更新后的音色信息，如果渠道不需要审核则直接返回 null
  Future<VoicePreset?> queryVoiceStatus({
    required String apiKey,
    required String voiceId,
    VoicePreset? voice,
  }) async {
    // 默认实现：不需要查询状态
    return null;
  }
}

/// TTS Provider 异常
class TtsProviderException implements Exception {
  final String message;
  final String? code;
  final dynamic originalError;

  TtsProviderException(
    this.message, {
    this.code,
    this.originalError,
  });

  @override
  String toString() => 'TtsProviderException: $message';
}
