import 'package:uuid/uuid.dart';

const _legacyBrokenNahidaPromptAudioUrl =
    'https://cdn.jsdelivr.net/gh/kuobibulaien/voicenxd.MP3';
const _previousDefaultNahidaPromptAudioUrl =
    'https://cdn.jsdelivr.net/gh/kuobibulaien/voice@main/nxd.MP3';
const _defaultNahidaPromptAudioUrl =
    'https://gcore.jsdelivr.net/gh/kuobibulaien/voice@main/nxd.MP3';

String? _normalizeUrl(String? url) {
  final trimmed = url?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return trimmed;
}

bool _isLegacyBrokenNahidaPromptAudioUrl(String url) {
  return url.trim().toLowerCase() ==
      _legacyBrokenNahidaPromptAudioUrl.toLowerCase();
}

String? _migratePromptAudioUrl(String? url) {
  final normalized = _normalizeUrl(url);
  if (normalized == null) return null;
  if (_isLegacyBrokenNahidaPromptAudioUrl(normalized)) {
    return _defaultNahidaPromptAudioUrl;
  }
  if (normalized.trim().toLowerCase() ==
      _previousDefaultNahidaPromptAudioUrl.toLowerCase()) {
    return _defaultNahidaPromptAudioUrl;
  }
  return normalized;
}

String _migrateBuiltInNahidaPromptAudioUrl(String? url) {
  final migrated = _migratePromptAudioUrl(url);
  return migrated ?? _defaultNahidaPromptAudioUrl;
}

/// 音色来源类型
enum VoiceSourceType {
  /// 公网 URL（支持所有模型）
  url,

  /// 本地文件上传（仅支持 Qwen-TTS）
  local,

  /// 从渠道商获取的预置音色
  preset,
}

/// 音色来源渠道
enum VoiceProviderType {
  /// 用户自定义（通过公网 URL 添加）
  custom,

  /// 阿里云（CosyVoice、Qwen-TTS）
  aliyun,

  /// 硅基流动
  siliconFlow,
}

/// 渠道绑定来源
enum VoiceBindingSourceKind {
  /// 从远端渠道创建得到
  remoteCreated,

  /// 用户手动填写
  manual,

  /// 从渠道列表导入
  imported,

  /// 从旧字段兼容迁移出的运行时绑定
  legacy,
}

String? _normalizeModelId(String? modelId) {
  final trimmed = modelId?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return trimmed;
}

String? _inferVoiceAdapterId({
  String? providerId,
  String? modelId,
}) {
  final normalizedProviderId = providerId?.trim().toLowerCase();
  final normalizedModelId = modelId?.trim().toLowerCase();
  if (normalizedProviderId == null || normalizedProviderId.isEmpty) {
    return null;
  }
  if (normalizedProviderId == 'aliyun') {
    if (normalizedModelId?.contains('qwen') == true) return 'aliyun_qwen';
    if (normalizedModelId?.contains('cosyvoice') == true) {
      return 'aliyun_cosyvoice';
    }
  }
  return normalizedProviderId;
}

bool _isAliyunBindingCandidate(VoiceChannelBinding binding) {
  final adapterId = binding.normalizedAdapterId;
  return binding.normalizedProviderId == 'aliyun' ||
      adapterId == 'aliyun_qwen' ||
      adapterId == 'aliyun_cosyvoice';
}

bool _isSiliconFlowBindingCandidate(VoiceChannelBinding binding) {
  final adapterId = binding.normalizedAdapterId;
  return binding.normalizedProviderId == 'siliconflow' ||
      adapterId == 'siliconflow';
}

/// 单个音色在某个渠道/模型下的远端绑定
class VoiceChannelBinding {
  final String providerId;
  final String providerName;
  final String? adapterId;
  final String? modelId;
  final String remoteVoiceId;
  final String? status;
  final VoiceBindingSourceKind sourceKind;

  const VoiceChannelBinding({
    required this.providerId,
    required this.providerName,
    required this.remoteVoiceId,
    this.adapterId,
    this.modelId,
    this.status,
    this.sourceKind = VoiceBindingSourceKind.remoteCreated,
  });

  String get normalizedProviderId => providerId.trim().toLowerCase();

  String? get normalizedAdapterId => adapterId?.trim().toLowerCase();

  String? get normalizedModelId => _normalizeModelId(modelId)?.toLowerCase();

  bool matches({
    String? providerId,
    String? adapterId,
    String? modelId,
  }) {
    final expectedProviderId = providerId?.trim().toLowerCase();
    final expectedAdapterId = adapterId?.trim().toLowerCase();
    final expectedModelId = _normalizeModelId(modelId)?.toLowerCase();

    if (expectedProviderId != null &&
        expectedProviderId.isNotEmpty &&
        normalizedProviderId != expectedProviderId) {
      final canFallbackToAdapter = expectedAdapterId != null &&
          expectedAdapterId.isNotEmpty &&
          normalizedAdapterId != null &&
          normalizedAdapterId == expectedAdapterId;
      if (!canFallbackToAdapter) {
        return false;
      }
    }
    if (expectedAdapterId != null &&
        expectedAdapterId.isNotEmpty &&
        normalizedAdapterId != null &&
        normalizedAdapterId != expectedAdapterId) {
      return false;
    }
    if (expectedModelId != null &&
        expectedModelId.isNotEmpty &&
        normalizedModelId != null &&
        normalizedModelId != expectedModelId) {
      return false;
    }
    return true;
  }

  int matchScore({
    String? providerId,
    String? adapterId,
    String? modelId,
  }) {
    if (!matches(
      providerId: providerId,
      adapterId: adapterId,
      modelId: modelId,
    )) {
      return -1;
    }

    var score = 0;
    final expectedProviderId = providerId?.trim().toLowerCase();
    final expectedAdapterId = adapterId?.trim().toLowerCase();
    final expectedModelId = _normalizeModelId(modelId)?.toLowerCase();

    if (expectedProviderId != null &&
        expectedProviderId.isNotEmpty &&
        normalizedProviderId == expectedProviderId) {
      score += 4;
    }
    if (expectedAdapterId != null &&
        expectedAdapterId.isNotEmpty &&
        normalizedAdapterId == expectedAdapterId) {
      score += 3;
    }
    if (expectedModelId != null &&
        expectedModelId.isNotEmpty &&
        normalizedModelId == expectedModelId) {
      score += 2;
    } else if (normalizedModelId == null || normalizedModelId!.isEmpty) {
      score += 1;
    }
    if (status == null || status!.isEmpty || status == 'OK') {
      score += 1;
    }
    return score;
  }

  Map<String, dynamic> toJson() {
    return {
      'providerId': providerId,
      'providerName': providerName,
      'adapterId': adapterId,
      'modelId': modelId,
      'remoteVoiceId': remoteVoiceId,
      'status': status,
      'sourceKind': sourceKind.name,
    };
  }

  factory VoiceChannelBinding.fromJson(Map<String, dynamic> json) {
    final sourceKindName = json['sourceKind'] as String?;
    final sourceKind = VoiceBindingSourceKind.values.firstWhere(
      (item) => item.name == sourceKindName,
      orElse: () => VoiceBindingSourceKind.remoteCreated,
    );
    return VoiceChannelBinding(
      providerId: json['providerId'] as String? ?? '',
      providerName: json['providerName'] as String? ?? '',
      adapterId: json['adapterId'] as String?,
      modelId: json['modelId'] as String?,
      remoteVoiceId: json['remoteVoiceId'] as String? ?? '',
      status: json['status'] as String?,
      sourceKind: sourceKind,
    );
  }
}

/// TTS 模型类型
enum TtsModelType {
  /// 阿里云 CosyVoice（需要先创建音色，获得 voice_id）
  cosyVoice,

  /// 阿里云 Qwen-TTS（需要先创建音色，获得 voice，支持本地上传）
  qwenTts,

  /// 硅基流动 IndexTTS-2（支持系统预置音色、用户上传音色、动态音色）
  siliconFlowIndexTts,
}

/// 音色预设
///
/// 存储单个音色的配置信息，支持多种 TTS 模型：
/// - CosyVoice（阿里云）：使用 aliyunVoiceId
/// - Qwen-TTS（阿里云）：使用 aliyunVoiceId，支持本地文件上传
/// - IndexTTS-2（硅基流动）：使用 siliconFlowVoiceUri 或系统预置音色
/// - 多渠道绑定：通过 bindings 挂多个渠道返回的音色 ID
///
/// 2026-01-27: 添加 providerType 标识音色来源渠道
class VoicePreset {
  /// 唯一标识
  final String id;

  /// 音色名称（如"温柔女声"、"活泼少女"）
  final String name;

  /// 音色来源类型（url / local / preset）
  final VoiceSourceType sourceType;

  /// 音色来源渠道（custom / aliyun / siliconFlow）
  final VoiceProviderType providerType;

  /// 参考音频 URL（用于 IndexTTS-2，或阿里云创建音色时使用）
  final String? promptAudioUrl;

  /// 参考文本（与参考音频对应）
  final String? promptText;

  /// 情感参考文本
  final String? emoText;

  /// 是否使用情感控制
  final bool useEmoText;

  /// 音色来源说明（如"b站 xxx UID:xxx"）
  final String? source;

  /// 是否为内置音色（内置音色不可删除）
  final bool isBuiltIn;

  /// 多渠道远端绑定列表
  final List<VoiceChannelBinding> bindings;

  // ========== 阿里云音色相关字段 ==========

  /// 阿里云音色 ID（CosyVoice 返回 voice_id，Qwen-TTS 返回 voice）
  final String? aliyunVoiceId;

  /// 阿里云音色对应的合成模型（如 cosyvoice-v3-plus、qwen3-tts-vc-realtime-2026-01-15）
  /// 创建音色时指定的 target_model，合成时必须使用相同模型
  final String? aliyunTargetModel;

  /// 阿里云音色状态（CosyVoice 需要轮询：DEPLOYING/OK/UNDEPLOYED）
  final String? aliyunVoiceStatus;

  // ========== 硅基流动音色相关字段 ==========

  /// 硅基流动音色 URI（上传音频后返回的 URI，格式如 speech:xxx:xxx）
  final String? siliconFlowVoiceUri;

  /// 硅基流动音色对应的模型（如 FunAudioLLM/CosyVoice2-0.5B、IndexTeam/IndexTTS-2）
  final String? siliconFlowModel;

  /// 本地音频文件路径（用于本地上传模式，文件保存在应用目录中）
  final String? localAudioPath;

  List<VoiceChannelBinding> get effectiveBindings {
    final merged = <VoiceChannelBinding>[];

    void addBinding(VoiceChannelBinding binding) {
      final normalizedRemoteVoiceId = binding.remoteVoiceId.trim();
      if (normalizedRemoteVoiceId.isEmpty) return;
      final exists = merged.any((item) {
        final sameProvider =
            item.normalizedProviderId == binding.normalizedProviderId;
        final sameAdapter = item.normalizedAdapterId != null &&
            binding.normalizedAdapterId != null &&
            item.normalizedAdapterId == binding.normalizedAdapterId;
        return (sameProvider || sameAdapter) &&
            item.normalizedModelId == binding.normalizedModelId &&
            item.remoteVoiceId.trim() == normalizedRemoteVoiceId;
      });
      if (!exists) {
        merged.add(binding);
      }
    }

    for (final binding in bindings) {
      addBinding(binding);
    }

    if (aliyunVoiceId != null && aliyunVoiceId!.trim().isNotEmpty) {
      addBinding(
        VoiceChannelBinding(
          providerId: 'aliyun',
          providerName: '阿里云',
          adapterId: _inferVoiceAdapterId(
            providerId: 'aliyun',
            modelId: aliyunTargetModel,
          ),
          modelId: aliyunTargetModel,
          remoteVoiceId: aliyunVoiceId!,
          status: aliyunVoiceStatus,
          sourceKind: VoiceBindingSourceKind.legacy,
        ),
      );
    }

    if (siliconFlowVoiceUri != null && siliconFlowVoiceUri!.trim().isNotEmpty) {
      addBinding(
        VoiceChannelBinding(
          providerId: 'siliconflow',
          providerName: '硅基流动',
          adapterId: 'siliconflow',
          modelId: siliconFlowModel,
          remoteVoiceId: siliconFlowVoiceUri!,
          sourceKind: VoiceBindingSourceKind.legacy,
        ),
      );
    }

    return List<VoiceChannelBinding>.unmodifiable(merged);
  }

  VoiceChannelBinding? resolveBinding({
    String? providerId,
    String? adapterId,
    String? modelId,
  }) {
    final expectedProviderId = providerId?.trim();
    final expectedAdapterId = adapterId?.trim().isNotEmpty == true
        ? adapterId!.trim()
        : _inferVoiceAdapterId(
            providerId: expectedProviderId,
            modelId: modelId,
          );

    VoiceChannelBinding? best;
    var bestScore = -1;
    for (final binding in effectiveBindings) {
      final score = binding.matchScore(
        providerId: expectedProviderId,
        adapterId: expectedAdapterId,
        modelId: modelId,
      );
      if (score > bestScore) {
        best = binding;
        bestScore = score;
      }
    }
    return best;
  }

  /// 判断音色是否可用于指定的模型
  ///
  /// [modelId] TTS 模型 ID，如 "cosyvoice-v3-plus"、"FunAudioLLM/CosyVoice2-0.5B"
  /// [providerId] 渠道 ID，用于判断是阿里云还是硅基流动
  bool canUseWithModel(String modelId, {String? providerId}) {
    final normalizedProviderId = providerId?.trim();
    final binding = resolveBinding(
      providerId: normalizedProviderId,
      modelId: modelId,
    );
    if (binding != null) {
      if (binding.adapterId == 'aliyun_cosyvoice' && binding.status != 'OK') {
        return false;
      }
      return true;
    }

    // 预置音色（渠道提供的固定音色）：只能用于对应渠道的模型
    if (sourceType == VoiceSourceType.preset) {
      if (providerType == VoiceProviderType.siliconFlow) {
        // 硅基流动预置音色：需要匹配模型
        return siliconFlowModel != null &&
            modelId.contains(siliconFlowModel!.split('/').last);
      }
      if (providerType == VoiceProviderType.aliyun) {
        // 阿里云预置音色：需要匹配模型
        return aliyunTargetModel != null &&
            modelId.contains(aliyunTargetModel!);
      }
      return false;
    }

    // 本地上传音色：可用于阿里云 Qwen-TTS（会自动创建音色ID）
    if (sourceType == VoiceSourceType.local) {
      // 有本地文件路径就可以用于 Qwen-TTS（会在首次使用时自动创建音色）
      final hasLocalFile = localAudioPath != null && localAudioPath!.isNotEmpty;
      final isQwenModel = modelId.toLowerCase().contains('qwen');
      return hasLocalFile && isQwenModel;
    }

    // ===== URL 类型音色（包括内置音色和用户自定义音色）=====
    //
    // 判断逻辑：只要有公网 URL (promptAudioUrl)，就能用于支持参考音频的模型
    // 支持参考音频的模型包括：
    // - 硅基流动：IndexTTS-2, CosyVoice2 等
    // - 阿里云：qwen-tts（通过 URL 直接传入）
    // - 其他支持参考音频的模型

    final hasPromptUrl = promptAudioUrl != null && promptAudioUrl!.isNotEmpty;

    // 判断是否为硅基流动模型
    final isSiliconFlowModel = modelId.contains('FunAudioLLM') ||
        modelId.contains('IndexTeam') ||
        modelId.contains('CosyVoice2');
    if (isSiliconFlowModel) {
      // 硅基流动支持动态音色（通过 references 传入 URL），有 promptAudioUrl 就行
      // 或者有已上传的 siliconFlowVoiceUri
      return hasPromptUrl ||
          (siliconFlowVoiceUri != null && siliconFlowVoiceUri!.isNotEmpty);
    }

    // 判断是否为阿里云模型
    final isAliyunModel =
        modelId.contains('cosyvoice') || modelId.contains('qwen');
    if (isAliyunModel) {
      // Qwen-TTS 支持直接传入 URL 参考音频
      if (modelId.contains('qwen') && hasPromptUrl) {
        return true;
      }
      // CosyVoice 需要先创建音色（有 aliyunVoiceId）
      if (aliyunVoiceId != null && aliyunVoiceId!.isNotEmpty) {
        if (aliyunTargetModel == null) return false;
        // CosyVoice 模型需要音色状态为 OK
        if (modelId.contains('cosyvoice') && aliyunVoiceStatus != 'OK')
          return false;
        return modelId.contains(aliyunTargetModel!.split('-').first);
      }
      return false;
    }

    // 其他模型（如 OpenAI TTS）：有 promptAudioUrl 即可
    return hasPromptUrl;
  }

  VoicePreset copyWithBindings(List<VoiceChannelBinding> newBindings) {
    VoiceChannelBinding? firstAliyunBinding;
    VoiceChannelBinding? firstSiliconFlowBinding;

    for (final binding in newBindings) {
      if (firstAliyunBinding == null && _isAliyunBindingCandidate(binding)) {
        firstAliyunBinding = binding;
      }
      if (firstSiliconFlowBinding == null &&
          _isSiliconFlowBindingCandidate(binding)) {
        firstSiliconFlowBinding = binding;
      }
    }

    return VoicePreset(
      id: id,
      name: name,
      sourceType: sourceType,
      providerType: providerType,
      promptAudioUrl: promptAudioUrl,
      promptText: promptText,
      emoText: emoText,
      useEmoText: useEmoText,
      source: source,
      isBuiltIn: isBuiltIn,
      bindings: newBindings,
      aliyunVoiceId: firstAliyunBinding?.remoteVoiceId,
      aliyunTargetModel: firstAliyunBinding?.modelId,
      aliyunVoiceStatus: firstAliyunBinding?.status,
      siliconFlowVoiceUri: firstSiliconFlowBinding?.remoteVoiceId,
      siliconFlowModel: firstSiliconFlowBinding?.modelId,
      localAudioPath: localAudioPath,
    );
  }

  /// 获取来源渠道的显示名称
  String get providerDisplayName {
    switch (providerType) {
      case VoiceProviderType.custom:
        return '自定义';
      case VoiceProviderType.aliyun:
        return '阿里云';
      case VoiceProviderType.siliconFlow:
        return '硅基流动';
    }
  }

  /// 是否已创建阿里云音色
  bool get hasAliyunVoice => aliyunVoiceId != null && aliyunVoiceId!.isNotEmpty;

  /// 阿里云音色是否可用（状态为 OK）
  bool get isAliyunVoiceReady => aliyunVoiceStatus == 'OK';

  /// 是否已上传硅基流动音色
  bool get hasSiliconFlowVoice =>
      siliconFlowVoiceUri != null && siliconFlowVoiceUri!.isNotEmpty;

  VoicePreset({
    String? id,
    required this.name,
    this.sourceType = VoiceSourceType.url,
    this.providerType = VoiceProviderType.custom,
    this.promptAudioUrl,
    this.promptText,
    this.emoText,
    this.useEmoText = false,
    this.source,
    this.isBuiltIn = false,
    List<VoiceChannelBinding>? bindings,
    this.aliyunVoiceId,
    this.aliyunTargetModel,
    this.aliyunVoiceStatus,
    this.siliconFlowVoiceUri,
    this.siliconFlowModel,
    this.localAudioPath,
  })  : bindings = List<VoiceChannelBinding>.unmodifiable(bindings ?? const []),
        id = id ?? const Uuid().v4();

  VoicePreset copyWith({
    String? id,
    String? name,
    VoiceSourceType? sourceType,
    VoiceProviderType? providerType,
    String? promptAudioUrl,
    String? promptText,
    String? emoText,
    bool? useEmoText,
    String? source,
    bool? isBuiltIn,
    List<VoiceChannelBinding>? bindings,
    String? aliyunVoiceId,
    String? aliyunTargetModel,
    String? aliyunVoiceStatus,
    String? siliconFlowVoiceUri,
    String? siliconFlowModel,
    String? localAudioPath,
  }) {
    return VoicePreset(
      id: id ?? this.id,
      name: name ?? this.name,
      sourceType: sourceType ?? this.sourceType,
      providerType: providerType ?? this.providerType,
      promptAudioUrl: promptAudioUrl ?? this.promptAudioUrl,
      promptText: promptText ?? this.promptText,
      emoText: emoText ?? this.emoText,
      useEmoText: useEmoText ?? this.useEmoText,
      source: source ?? this.source,
      isBuiltIn: isBuiltIn ?? this.isBuiltIn,
      bindings: bindings ?? this.bindings,
      aliyunVoiceId: aliyunVoiceId ?? this.aliyunVoiceId,
      aliyunTargetModel: aliyunTargetModel ?? this.aliyunTargetModel,
      aliyunVoiceStatus: aliyunVoiceStatus ?? this.aliyunVoiceStatus,
      siliconFlowVoiceUri: siliconFlowVoiceUri ?? this.siliconFlowVoiceUri,
      siliconFlowModel: siliconFlowModel ?? this.siliconFlowModel,
      localAudioPath: localAudioPath ?? this.localAudioPath,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'sourceType': sourceType.name,
      'providerType': providerType.name,
      'promptAudioUrl': promptAudioUrl,
      'promptText': promptText,
      'emoText': emoText,
      'useEmoText': useEmoText,
      'source': source,
      'isBuiltIn': isBuiltIn,
      'bindings': bindings.map((e) => e.toJson()).toList(),
      'aliyunVoiceId': aliyunVoiceId,
      'aliyunTargetModel': aliyunTargetModel,
      'aliyunVoiceStatus': aliyunVoiceStatus,
      'siliconFlowVoiceUri': siliconFlowVoiceUri,
      'siliconFlowModel': siliconFlowModel,
      'localAudioPath': localAudioPath,
    };
  }

  factory VoicePreset.fromJson(Map<String, dynamic> json) {
    // 解析 sourceType，兼容旧数据（没有 sourceType 字段的默认为 url）
    VoiceSourceType sourceType = VoiceSourceType.url;
    final sourceTypeStr = json['sourceType'] as String?;
    if (sourceTypeStr != null) {
      sourceType = VoiceSourceType.values.firstWhere(
        (e) => e.name == sourceTypeStr,
        orElse: () => VoiceSourceType.url,
      );
    }

    // 解析 providerType，兼容旧数据（没有 providerType 字段的默认为 custom）
    VoiceProviderType providerType = VoiceProviderType.custom;
    final providerTypeStr = json['providerType'] as String?;
    if (providerTypeStr != null) {
      providerType = VoiceProviderType.values.firstWhere(
        (e) => e.name == providerTypeStr,
        orElse: () => VoiceProviderType.custom,
      );
    }

    final presetId = json['id'] as String?;
    String? promptAudioUrl =
        _migratePromptAudioUrl(json['promptAudioUrl'] as String?);
    if (presetId == 'built_in_nahida') {
      promptAudioUrl = _migrateBuiltInNahidaPromptAudioUrl(promptAudioUrl);
    }

    final bindings = (json['bindings'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map>()
        .map((item) => VoiceChannelBinding.fromJson(
              item.cast<String, dynamic>(),
            ))
        .toList();

    return VoicePreset(
      id: presetId,
      name: json['name'] as String? ?? '未命名音色',
      sourceType: sourceType,
      providerType: providerType,
      promptAudioUrl: promptAudioUrl,
      promptText: json['promptText'] as String?,
      emoText: json['emoText'] as String?,
      useEmoText: json['useEmoText'] as bool? ?? false,
      source: json['source'] as String?,
      isBuiltIn: json['isBuiltIn'] as bool? ?? false,
      bindings: bindings,
      aliyunVoiceId: json['aliyunVoiceId'] as String?,
      aliyunTargetModel: json['aliyunTargetModel'] as String?,
      aliyunVoiceStatus: json['aliyunVoiceStatus'] as String?,
      siliconFlowVoiceUri: json['siliconFlowVoiceUri'] as String?,
      siliconFlowModel: json['siliconFlowModel'] as String?,
      localAudioPath: json['localAudioPath'] as String?,
    );
  }

  /// 内置默认音色
  static VoicePreset get defaultPreset => VoicePreset(
        id: 'built_in_nahida',
        name: '纳西妲（仿）',
        sourceType: VoiceSourceType.url,
        providerType: VoiceProviderType.custom,
        promptAudioUrl: _defaultNahidaPromptAudioUrl,
        promptText:
            '要准备睡下午觉了哦，躺过来吧。嗯，我们一起睡午觉吧。晚安，亲爱的，晚安吻的话，等你睡完觉我就亲你，怎么样。那要快点睡觉哦。嗯？想抱着我睡？一直都是可以哟，但是你要答应我好好睡觉。嗯~就是这样，闭眼睡觉觉吧。',
        source: 'b站 月下专属人类 UID:1838261330',
        isBuiltIn: true,
      );
}

/// TTS 插件配置
///
/// 重构说明：API Key 和 URL 已迁移到统一模型管理（ProviderAuth），
/// TtsConfig 只保留业务配置和渠道选择。
///
/// 2026-01-25: 添加模型选择，支持两步选择（渠道 → 模型）
class TtsConfig {
  /// 是否启用 TTS 插件
  final bool enabled;

  /// 选中的 TTS 渠道 ID（对应 ProviderAuth.id）
  final String? selectedProviderId;

  /// 选中的 TTS 模型 ID（从渠道的 models 列表中选择）
  final String? selectedModelId;

  /// TTS 模型名称（如 tts-1、IndexTTS-2）- 兼容旧配置
  final String? model;

  /// 语音角色（如 alloy、echo、fable 等，OpenAI TTS 专用）
  final String? voice;

  /// 参考音频 URL（用于克隆声音，IndexTTS 专用）
  final String? promptAudioUrl;

  /// 参考文本（与参考音频对应的文本，IndexTTS 专用）
  final String? promptText;

  /// 情感参考文本（IndexTTS-2 专用，用于控制语气情感）
  final String? emoText;

  /// 是否使用情感文本（IndexTTS-2 专用）
  final bool useEmoText;

  /// 音色预设列表
  final List<VoicePreset> voicePresets;

  /// 当前选中的音色预设 ID
  final String? selectedVoicePresetId;

  /// 语速 (0.5 ~ 2.0)
  final double? speed;

  /// 最大字数限制（超过此限制会自动拆分）
  final int maxCharsPerChunk;

  /// 语音使用频率 (0-100)
  /// 0 = 从不使用语音，100 = 尽可能使用语音
  /// 默认 30 = 偶尔使用（重点内容）
  final int voiceFrequency;

  /// 系统提示词模板
  final String systemPromptTemplate;

  TtsConfig({
    this.enabled = false,
    this.selectedProviderId,
    this.selectedModelId,
    this.model,
    this.voice,
    this.promptAudioUrl,
    this.promptText,
    this.emoText,
    this.useEmoText = false,
    List<VoicePreset>? voicePresets,
    String? selectedVoicePresetId,
    this.speed,
    this.maxCharsPerChunk = 20,
    this.voiceFrequency = 60, // 默认"正常"档位
    String? systemPromptTemplate,
  })  : voicePresets = voicePresets ?? [VoicePreset.defaultPreset],
        selectedVoicePresetId = selectedVoicePresetId ?? 'built_in_nahida',
        systemPromptTemplate =
            systemPromptTemplate ?? _defaultSystemPromptTemplate;

  static const String _defaultSystemPromptTemplate = '''
你可以使用 <tts>文本</tts> 标记来生成语音（降级模式）。

使用规则：
1. 将需要转换为语音的文本用 <tts></tts> 标记包裹
2. 每个 <tts></tts> 标记内的文本不要超过 20 个字
3. 一轮对话中可以使用多个 <tts></tts> 标记
4. 建议在关键句子或回复的重要部分使用语音

示例：
<tts>你好，很高兴见到你！</tts>
<tts>今天天气真不错。</tts>
''';

  TtsConfig copyWith({
    bool? enabled,
    String? selectedProviderId,
    String? selectedModelId,
    String? model,
    String? voice,
    String? promptAudioUrl,
    String? promptText,
    String? emoText,
    bool? useEmoText,
    List<VoicePreset>? voicePresets,
    String? selectedVoicePresetId,
    double? speed,
    int? maxCharsPerChunk,
    int? voiceFrequency,
    String? systemPromptTemplate,
  }) {
    return TtsConfig(
      enabled: enabled ?? this.enabled,
      selectedProviderId: selectedProviderId ?? this.selectedProviderId,
      selectedModelId: selectedModelId ?? this.selectedModelId,
      model: model ?? this.model,
      voice: voice ?? this.voice,
      promptAudioUrl: promptAudioUrl ?? this.promptAudioUrl,
      promptText: promptText ?? this.promptText,
      emoText: emoText ?? this.emoText,
      useEmoText: useEmoText ?? this.useEmoText,
      voicePresets: voicePresets ?? this.voicePresets,
      selectedVoicePresetId:
          selectedVoicePresetId ?? this.selectedVoicePresetId,
      speed: speed ?? this.speed,
      maxCharsPerChunk: maxCharsPerChunk ?? this.maxCharsPerChunk,
      voiceFrequency: voiceFrequency ?? this.voiceFrequency,
      systemPromptTemplate: systemPromptTemplate ?? this.systemPromptTemplate,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'enabled': enabled,
      'selectedProviderId': selectedProviderId,
      'selectedModelId': selectedModelId,
      'model': model,
      'voice': voice,
      'promptAudioUrl': promptAudioUrl,
      'promptText': promptText,
      'emoText': emoText,
      'useEmoText': useEmoText,
      'voicePresets': voicePresets.map((e) => e.toJson()).toList(),
      'selectedVoicePresetId': selectedVoicePresetId,
      'speed': speed,
      'maxCharsPerChunk': maxCharsPerChunk,
      'voiceFrequency': voiceFrequency,
      'systemPromptTemplate': systemPromptTemplate,
    };
  }

  factory TtsConfig.fromJson(Map<String, dynamic> json) {
    // 解析存储的音色列表
    var presets = (json['voicePresets'] as List<dynamic>?)
            ?.map((e) => VoicePreset.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];

    // 确保内置音色存在（如果被删除了就加回来）
    final hasBuiltIn = presets.any((p) => p.id == 'built_in_nahida');
    if (!hasBuiltIn) {
      presets = [VoicePreset.defaultPreset, ...presets];
    }

    return TtsConfig(
      enabled: json['enabled'] as bool? ?? false,
      selectedProviderId: json['selectedProviderId'] as String?,
      selectedModelId: json['selectedModelId'] as String?,
      model: json['model'] as String?,
      voice: json['voice'] as String?,
      promptAudioUrl: _migratePromptAudioUrl(json['promptAudioUrl'] as String?),
      promptText: json['promptText'] as String?,
      emoText: json['emoText'] as String?,
      useEmoText: json['useEmoText'] as bool? ?? false,
      voicePresets: presets,
      selectedVoicePresetId: json['selectedVoicePresetId'] as String?,
      speed: (json['speed'] as num?)?.toDouble(),
      maxCharsPerChunk: json['maxCharsPerChunk'] as int? ?? 20,
      voiceFrequency: json['voiceFrequency'] as int? ?? 60, // 默认"正常"档位
      systemPromptTemplate: json['systemPromptTemplate'] as String?,
    );
  }

  /// 获取当前选中的音色预设
  VoicePreset? get selectedVoicePreset {
    if (selectedVoicePresetId == null) return null;
    return voicePresets.where((p) => p.id == selectedVoicePresetId).firstOrNull;
  }

  /// 获取当前生效的参考音频URL（优先使用选中的音色预设）
  String? get effectivePromptAudioUrl {
    return selectedVoicePreset?.promptAudioUrl ?? promptAudioUrl;
  }

  /// 获取当前生效的参考文本（优先使用选中的音色预设）
  String? get effectivePromptText {
    return selectedVoicePreset?.promptText ?? promptText;
  }

  /// 获取当前生效的情感文本（优先使用选中的音色预设）
  String? get effectiveEmoText {
    final preset = selectedVoicePreset;
    if (preset != null && preset.useEmoText) {
      return preset.emoText;
    }
    return useEmoText ? emoText : null;
  }
}
