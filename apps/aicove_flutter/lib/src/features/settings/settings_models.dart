/// 设置相关数据模型
///
/// 从 app_settings.dart 提取，包含枚举类型和数据类。
///
/// 更新记录：
/// - 2025-12-31: 从 app_settings.dart 提取
library;

import 'package:flutter/material.dart';
import '../../core/api/thinking/thinking_level.dart';
import '../../core/utils/message_formatter.dart';
import '../../core/utils/token_estimator.dart';
import '../../core/prompts/prompt_builtin_defaults.g.dart';
import '../../ui/theme/tokens.dart';

export '../../core/api/thinking/thinking_level.dart' show ThinkingLevel;

/// 模型类型枚举
enum ModelType {
  chat('chat', '对话', Icons.chat_bubble_outline, Color(0xFF4A90E2)),
  embedding('embedding', '嵌入', Icons.link, Color(0xFF10B981)),
  tts('tts', '语音合成', Icons.volume_up_outlined, Color(0xFFEC4899)),
  stt('stt', '语音识别', Icons.mic_outlined, Color(0xFFF59E0B)),
  image('image', '图像生成', Icons.image_outlined, Color(0xFF8B5CF6));

  const ModelType(this.value, this.label, this.icon, this.color);
  final String value;
  final String label;
  final IconData icon;
  final Color color;

  static ModelType fromValue(String? value) {
    for (final type in ModelType.values) {
      if (type.value == value) return type;
    }
    return ModelType.chat;
  }

  /// 根据模型ID自动推断类型
  static ModelType inferFromModelId(String modelId) {
    final id = modelId.trim().toLowerCase();
    final rawId = id.contains(':') ? id.split(':').last.trim() : id;

    if (_openAiTtsVoiceIds.contains(rawId)) {
      return ModelType.tts;
    }

    // TTS 模型识别
    if (_ttsPatterns.hasMatch(id)) {
      return ModelType.tts;
    }

    // STT 模型识别
    if (_sttPatterns.hasMatch(id)) {
      return ModelType.stt;
    }

    // Embedding 模型识别
    if (_embeddingPatterns.hasMatch(id)) {
      return ModelType.embedding;
    }

    // 图像生成模型识别
    if (_imagePatterns.hasMatch(id)) {
      return ModelType.image;
    }

    // 默认为对话模型
    return ModelType.chat;
  }
}

const _openAiTtsVoiceIds = <String>{
  'alloy',
  'echo',
  'fable',
  'onyx',
  'nova',
  'shimmer',
};

// TTS 模型匹配规则
final _ttsPatterns = RegExp(
  r'\b('
  r'tts|'
  r'text-to-speech|'
  r'speech-synthesis|'
  r'speech-\d[\d.]*(?:-hd|-turbo)|' // MiniMax TTS
  r'cosyvoice|' // 阿里云语音
  r'sambert|'
  r'fish-speech|'
  r'chattts|'
  r'edge-tts|'
  r'azure-tts|'
  r'elevenlabs'
  r')\b',
  caseSensitive: false,
);

// STT 模型匹配规则
final _sttPatterns = RegExp(
  r'\b('
  r'whisper|'
  r'stt|'
  r'speech-to-text|'
  r'transcription|'
  r'asr|' // Automatic Speech Recognition
  r'paraformer|' // 阿里达摩院
  r'sensevoice|'
  r'funasr'
  r')\b',
  caseSensitive: false,
);

// Embedding 模型匹配规则
final _embeddingPatterns = RegExp(
  r'\b('
  r'embed|'
  r'embedding|'
  r'text-embedding|'
  r'ada-002|'
  r'bge-|' // BAAI BGE
  r'm3e-|' // M3E
  r'gte-|' // GTE
  r'e5-|' // E5
  r'jina-embed|'
  r'voyage-|'
  r'cohere-embed'
  r')\b',
  caseSensitive: false,
);

// 图像生成模型匹配规则
final _imagePatterns = RegExp(
  r'\b('
  r'dall-e|'
  r'dalle|'
  r'midjourney|'
  r'stable-diffusion|'
  r'sd-|'
  r'sdxl|'
  r'flux|'
  r'imagen|'
  r'ideogram|'
  r'playground|'
  r'kandinsky|'
  r'cogview|'
  r'wanx|' // 通义万相
  r'nai-diffusion|' // NovelAI
  r'novelai'
  r')\b',
  caseSensitive: false,
);

/// 对话模型能力（仅适用于 chat 模型）
enum ChatModelCapability {
  vision('vision'),
  tools('tools'),
  reasoning('reasoning'),
  web('web');

  const ChatModelCapability(this.value);
  final String value;

  static ChatModelCapability? fromValue(String value) {
    final normalized = value.trim().toLowerCase();
    for (final capability in ChatModelCapability.values) {
      if (capability.value == normalized) return capability;
    }
    return null;
  }

  static List<ChatModelCapability> fromValues(Iterable<dynamic>? values) {
    if (values == null) return const <ChatModelCapability>[];
    final result = <ChatModelCapability>[];
    for (final raw in values) {
      final capability = fromValue(raw?.toString() ?? '');
      if (capability != null && !result.contains(capability)) {
        result.add(capability);
      }
    }
    return result;
  }

  static List<String> normalizeValues(Iterable<dynamic>? values) {
    return fromValues(values).map((e) => e.value).toList();
  }
}

// Chat 能力识别规则（自动推断）
final _chatVisionPatterns = RegExp(
  r'\b('
  r'vision|'
  r'vl\b|'
  r'4o|'
  r'gpt-4-turbo|'
  r'gpt-4\.1|'
  r'gpt-5|'
  r'claude-3|'
  r'claude-.*-4|'
  r'gemini|'
  r'gemma-3|'
  r'glm-4v|'
  r'qvq|'
  r'o1(?!-mini)|'
  r'o3(?!-mini)|'
  r'o4|'
  r'grok-vision|'
  r'grok-4|'
  r'pixtral|'
  r'llava|'
  r'moondream|'
  r'minicpm|'
  r'internvl'
  r')\b',
  caseSensitive: false,
);

final _chatToolsPatterns = RegExp(
  r'\b('
  r'gpt-4|'
  r'gpt-3\.5-turbo|'
  r'gpt-5|'
  r'o1|o3|o4|'
  r'claude|'
  r'qwen|'
  r'deepseek(?!-vl)|'
  r'glm-5|'
  r'glm-4|'
  r'gemini|'
  r'grok|'
  r'hunyuan|'
  r'doubao|'
  r'minimax|'
  r'kimi'
  r')\b',
  caseSensitive: false,
);

final _chatReasoningPatterns = RegExp(
  r'\b('
  r'o1|o3|o4|'
  r'qwq|'
  r'reasoner|'
  r'reasoning|'
  r'thinking|'
  r'think\b|'
  r'r1\b|'
  r'glm-5|'
  r'hunyuan-t1|'
  r'glm-zero|'
  r'deepseek-r|'
  r'marco-o1'
  r')\b',
  caseSensitive: false,
);

final _chatWebPatterns = RegExp(
  r'\b('
  r'search|'
  r'online|'
  r'web|'
  r'sonar|'
  r'realtime|'
  r'perplexity'
  r')\b',
  caseSensitive: false,
);

List<ChatModelCapability> inferChatModelCapabilities(String modelId) {
  final id = modelId.toLowerCase();
  final result = <ChatModelCapability>[];
  if (_chatVisionPatterns.hasMatch(id)) {
    result.add(ChatModelCapability.vision);
  }
  if (_chatToolsPatterns.hasMatch(id)) {
    result.add(ChatModelCapability.tools);
  }
  if (_chatReasoningPatterns.hasMatch(id)) {
    result.add(ChatModelCapability.reasoning);
  }
  if (_chatWebPatterns.hasMatch(id)) {
    result.add(ChatModelCapability.web);
  }
  return result;
}

/// 全局背景色选项（影响整个 App 的 Scaffold 底色）
enum GlobalBackgroundColor {
  white('white', '纯白', Color(0xFFFFFFFF)),
  momotalk('momotalk', 'Momotalk', Color(0xFFF3F6F8));

  const GlobalBackgroundColor(this.value, this.label, this.color);
  final String value;
  final String label;
  final Color color;

  static GlobalBackgroundColor fromValue(String? value) {
    for (final bg in GlobalBackgroundColor.values) {
      if (bg.value == value) return bg;
    }
    return GlobalBackgroundColor.white;
  }
}

/// 聊天背景色选项
enum ChatBackgroundColor {
  /// 默认色 - 跟随全局背景色
  defaultColor('default', '默认', null),
  white('white', '纯白', Color(0xFFFFFFFF)),

  /// Momotalk 经典皮肤：浅灰背景 + 粉色强调（AppBar/主按钮）
  momotalk(
    'momotalk',
    'Momotalk',
    Color(0xFFF3F6F8),
    accentColor: Color(0xFFFC96AA),
  ),
  warm('warm', '暖色', Color(0xFFFFF7E1));

  const ChatBackgroundColor(
    this.value,
    this.label,
    this.color, {
    this.accentColor,
  });
  final String value;
  final String label;

  /// 背景色，null 表示跟随全局背景色
  final Color? color;

  /// 该皮肤预设的强调色（null 表示沿用用户自定义主题色）
  final Color? accentColor;

  /// 是否跟随全局背景色
  bool get isDefault => this == ChatBackgroundColor.defaultColor;

  static ChatBackgroundColor fromValue(String? value) {
    for (final bg in ChatBackgroundColor.values) {
      if (bg.value == value) return bg;
    }
    return ChatBackgroundColor.defaultColor;
  }
}

/// 自动回复设置
class AutoReplySettings {
  final bool enabled;
  final bool guardModeEnabled;
  final int dailyLimit;
  final int minIntervalMinutes;
  final bool quietHoursEnabled;
  final String quietHoursStart;
  final String quietHoursEnd;
  final bool allowExactAlarm;
  final bool allowAiSetReminders;
  final String analyzerPrompt;
  final String? analyzerModel;
  final String? analyzerProvider;

  static const String defaultAnalyzerPrompt =
      PromptBuiltinDefaults.autoReplyAnalyzerDefault;

  const AutoReplySettings({
    this.enabled = false,
    this.guardModeEnabled = false,
    this.dailyLimit = 3,
    this.minIntervalMinutes = 120,
    this.quietHoursEnabled = true,
    this.quietHoursStart = '22:00',
    this.quietHoursEnd = '08:00',
    this.allowExactAlarm = false,
    this.allowAiSetReminders = true,
    this.analyzerPrompt = defaultAnalyzerPrompt,
    this.analyzerModel,
    this.analyzerProvider,
  });

  AutoReplySettings copyWith({
    bool? enabled,
    bool? guardModeEnabled,
    int? dailyLimit,
    int? minIntervalMinutes,
    bool? quietHoursEnabled,
    String? quietHoursStart,
    String? quietHoursEnd,
    bool? allowExactAlarm,
    bool? allowAiSetReminders,
    String? analyzerPrompt,
    String? analyzerModel,
    String? analyzerProvider,
    bool clearAnalyzerModel = false,
    bool clearAnalyzerProvider = false,
  }) {
    return AutoReplySettings(
      enabled: enabled ?? this.enabled,
      guardModeEnabled: guardModeEnabled ?? this.guardModeEnabled,
      dailyLimit: dailyLimit ?? this.dailyLimit,
      minIntervalMinutes: minIntervalMinutes ?? this.minIntervalMinutes,
      quietHoursEnabled: quietHoursEnabled ?? this.quietHoursEnabled,
      quietHoursStart: quietHoursStart ?? this.quietHoursStart,
      quietHoursEnd: quietHoursEnd ?? this.quietHoursEnd,
      allowExactAlarm: allowExactAlarm ?? this.allowExactAlarm,
      allowAiSetReminders: allowAiSetReminders ?? this.allowAiSetReminders,
      analyzerPrompt: analyzerPrompt ?? this.analyzerPrompt,
      analyzerModel: clearAnalyzerModel
          ? null
          : (analyzerModel ?? this.analyzerModel),
      analyzerProvider: clearAnalyzerProvider
          ? null
          : (analyzerProvider ?? this.analyzerProvider),
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'guard_mode_enabled': guardModeEnabled,
    'daily_limit': dailyLimit,
    'min_interval_minutes': minIntervalMinutes,
    'quiet_hours_enabled': quietHoursEnabled,
    'quiet_hours_start': quietHoursStart,
    'quiet_hours_end': quietHoursEnd,
    'allow_exact_alarm': allowExactAlarm,
    'allow_ai_set_reminders': allowAiSetReminders,
    'analyzer_prompt': analyzerPrompt,
    'analyzer_model': analyzerModel,
    'analyzer_provider': analyzerProvider,
  };

  factory AutoReplySettings.fromJson(Map<String, dynamic> json) {
    String normalizeTime(String? value, String fallback) {
      if (value == null || value.isEmpty) return fallback;
      final parts = value.split(':');
      if (parts.length != 2) return fallback;
      final h = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      if (h == null || m == null) return fallback;
      final hh = h.clamp(0, 23).toInt().toString().padLeft(2, '0');
      final mm = m.clamp(0, 59).toInt().toString().padLeft(2, '0');
      return '$hh:$mm';
    }

    int clampInt(num? value, int min, int max, int fallback) {
      if (value == null) return fallback;
      final v = value.toInt();
      if (v < min) return min;
      if (v > max) return max;
      return v;
    }

    String normalizeAnalyzerPrompt(dynamic value) {
      final prompt = value is String ? value.trim() : '';
      if (prompt.isEmpty) {
        return defaultAnalyzerPrompt;
      }
      return prompt;
    }

    return AutoReplySettings(
      enabled: json['enabled'] == true,
      guardModeEnabled: json['guard_mode_enabled'] == true,
      dailyLimit: clampInt(json['daily_limit'] as num?, 1, 10, 3),
      minIntervalMinutes: clampInt(
        json['min_interval_minutes'] as num?,
        15,
        720,
        120,
      ),
      quietHoursEnabled: json['quiet_hours_enabled'] != false,
      quietHoursStart: normalizeTime(
        json['quiet_hours_start'] as String?,
        '22:00',
      ),
      quietHoursEnd: normalizeTime(json['quiet_hours_end'] as String?, '08:00'),
      allowExactAlarm: json['allow_exact_alarm'] == true,
      allowAiSetReminders: json['allow_ai_set_reminders'] != false,
      analyzerPrompt: normalizeAnalyzerPrompt(json['analyzer_prompt']),
      analyzerModel: json['analyzer_model'] as String?,
      analyzerProvider: json['analyzer_provider'] as String?,
    );
  }
}

/// 增强对话设置（调试工具）
class EnhancedDialogueSettings {
  final bool enabled;
  final String systemPrompt;
  final String bootstrapUserMessage;
  final int recentRounds;

  static const String defaultSystemPrompt =
      PromptBuiltinDefaults.enhancedDialogueSystemDefault;

  static const String defaultBootstrapUserMessage =
      PromptBuiltinDefaults.enhancedDialogueBootstrapUserDefault;

  const EnhancedDialogueSettings({
    this.enabled = false,
    this.systemPrompt = defaultSystemPrompt,
    this.bootstrapUserMessage = defaultBootstrapUserMessage,
    this.recentRounds = 3,
  });

  EnhancedDialogueSettings copyWith({
    bool? enabled,
    String? systemPrompt,
    String? bootstrapUserMessage,
    int? recentRounds,
  }) {
    return EnhancedDialogueSettings(
      enabled: enabled ?? this.enabled,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      bootstrapUserMessage: bootstrapUserMessage ?? this.bootstrapUserMessage,
      recentRounds: recentRounds ?? this.recentRounds,
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'system_prompt': systemPrompt,
    'bootstrap_user_message': bootstrapUserMessage,
    'recent_rounds': recentRounds,
  };

  factory EnhancedDialogueSettings.fromJson(Map<String, dynamic> json) {
    int normalizeRounds(num? value) {
      final v = value?.toInt() ?? 3;
      if (v < 1) return 1;
      if (v > 20) return 20;
      return v;
    }

    final systemPrompt = (json['system_prompt'] as String?)?.trim();
    final bootstrap = (json['bootstrap_user_message'] as String?)?.trim();

    return EnhancedDialogueSettings(
      enabled: json['enabled'] == true,
      systemPrompt: systemPrompt?.isNotEmpty == true
          ? systemPrompt!
          : defaultSystemPrompt,
      bootstrapUserMessage: bootstrap?.isNotEmpty == true
          ? bootstrap!
          : defaultBootstrapUserMessage,
      recentRounds: normalizeRounds(json['recent_rounds'] as num?),
    );
  }
}

/// 调用流程模式
enum CallFlowMode {
  auto('auto', '自动'),
  fast('fast', '快速');

  const CallFlowMode(this.value, this.label);
  final String value;
  final String label;

  static CallFlowMode fromValue(String? value) {
    final normalized = value?.trim().toLowerCase();
    if (normalized == 'stable') {
      return CallFlowMode.auto;
    }
    for (final mode in CallFlowMode.values) {
      if (mode.value == normalized) return mode;
    }
    return CallFlowMode.auto;
  }
}

enum EffectiveImageGenerationRoute {
  stable('stable'),
  fast('fast');

  const EffectiveImageGenerationRoute(this.value);
  final String value;
}

/// 调用流程设置（生图路径 + 超时）
class CallFlowSettings {
  static const int minModelTimeoutSeconds = 10;
  static const int maxModelTimeoutSeconds = 300;
  static const int minToolTimeoutSeconds = 1;
  static const int maxToolTimeoutSeconds = 120;

  final CallFlowMode mode;
  final int modelTimeoutSeconds;
  final int toolTimeoutSeconds;

  const CallFlowSettings({
    this.mode = CallFlowMode.auto,
    this.modelTimeoutSeconds = 120,
    this.toolTimeoutSeconds = 30,
  });

  CallFlowSettings copyWith({
    CallFlowMode? mode,
    int? modelTimeoutSeconds,
    int? toolTimeoutSeconds,
  }) {
    return CallFlowSettings(
      mode: mode ?? this.mode,
      modelTimeoutSeconds: (modelTimeoutSeconds ?? this.modelTimeoutSeconds)
          .clamp(minModelTimeoutSeconds, maxModelTimeoutSeconds),
      toolTimeoutSeconds: (toolTimeoutSeconds ?? this.toolTimeoutSeconds).clamp(
        minToolTimeoutSeconds,
        maxToolTimeoutSeconds,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'mode': mode.value,
    'model_timeout_seconds': modelTimeoutSeconds,
    'tool_timeout_seconds': toolTimeoutSeconds,
  };

  factory CallFlowSettings.fromJson(Map<String, dynamic> json) {
    int clampInt(num? value, int min, int max, int fallback) {
      if (value == null) return fallback;
      final v = value.toInt();
      if (v < min) return min;
      if (v > max) return max;
      return v;
    }

    const defaults = CallFlowSettings();
    return CallFlowSettings(
      mode: CallFlowMode.fromValue(json['mode'] as String?),
      modelTimeoutSeconds: clampInt(
        json['model_timeout_seconds'] as num?,
        minModelTimeoutSeconds,
        maxModelTimeoutSeconds,
        defaults.modelTimeoutSeconds,
      ),
      toolTimeoutSeconds: clampInt(
        json['tool_timeout_seconds'] as num?,
        minToolTimeoutSeconds,
        maxToolTimeoutSeconds,
        defaults.toolTimeoutSeconds,
      ),
    );
  }
}

/// 自定义模型配置
class CustomModel {
  final String name;
  final String? displayName;
  final String apiKey;
  final String apiBaseUrl;
  final String provider;

  const CustomModel({
    required this.name,
    this.displayName,
    required this.apiKey,
    required this.apiBaseUrl,
    this.provider = 'openai',
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'displayName': displayName,
    'apiKey': apiKey,
    'apiBaseUrl': apiBaseUrl,
    'provider': provider,
  };

  factory CustomModel.fromJson(Map<String, dynamic> json) => CustomModel(
    name: (json['name'] as String?) ?? '',
    displayName: json['displayName'] as String?,
    apiKey: (json['apiKey'] as String?) ?? '',
    apiBaseUrl: (json['apiBaseUrl'] as String?) ?? 'https://api.openai.com/v1',
    provider: (json['provider'] as String?) ?? 'openai',
  );
}

/// 提供商认证配置
class ProviderAuth {
  final String id;
  final String? displayName;
  final List<String> apiKeys;
  final String apiBaseUrl;
  final bool enabled;
  final List<String> models;
  final List<String> visibleModels;
  final List<String> hiddenModels;
  final List<String> capabilities;
  final Map<String, dynamic> customConfig;

  /// 是否禁用工具调用，默认 false（即默认启用工具调用）
  final bool disableToolCalling;

  /// 温度参数，null 表示使用全局默认值
  final double? temperature;

  /// Top P 参数，null 表示不覆盖，使用提供商默认
  final double? topP;

  /// 上下文消息数量限制，null 表示不限制，超过时自动截断
  final int? contextMessageLimit;

  /// 最大上下文 Token 数，null 表示使用硬编码表或兜底值
  final int? maxContextTokens;

  const ProviderAuth({
    required this.id,
    this.displayName,
    required this.apiKeys,
    required this.apiBaseUrl,
    this.enabled = true,
    this.models = const <String>[],
    this.visibleModels = const <String>[],
    this.hiddenModels = const <String>[],
    this.capabilities = const <String>['chat'],
    this.customConfig = const <String, dynamic>{},
    this.disableToolCalling = false,
    this.temperature,
    this.topP,
    this.contextMessageLimit,
    this.maxContextTokens,
  });

  ProviderAuth copyWith({
    String? id,
    String? displayName,
    List<String>? apiKeys,
    String? apiBaseUrl,
    bool? enabled,
    List<String>? models,
    List<String>? visibleModels,
    List<String>? hiddenModels,
    List<String>? capabilities,
    Map<String, dynamic>? customConfig,
    bool? disableToolCalling,
    double? temperature,
    double? topP,
    int? contextMessageLimit,
    int? maxContextTokens,
    bool clearTemperature = false,
    bool clearTopP = false,
    bool clearContextMessageLimit = false,
    bool clearMaxContextTokens = false,
  }) => ProviderAuth(
    id: id ?? this.id,
    displayName: displayName ?? this.displayName,
    apiKeys: apiKeys ?? this.apiKeys,
    apiBaseUrl: apiBaseUrl ?? this.apiBaseUrl,
    enabled: enabled ?? this.enabled,
    models: models ?? this.models,
    visibleModels: visibleModels ?? this.visibleModels,
    hiddenModels: hiddenModels ?? this.hiddenModels,
    capabilities: capabilities ?? this.capabilities,
    customConfig: customConfig ?? this.customConfig,
    disableToolCalling: disableToolCalling ?? this.disableToolCalling,
    temperature: clearTemperature ? null : (temperature ?? this.temperature),
    topP: clearTopP ? null : (topP ?? this.topP),
    contextMessageLimit: clearContextMessageLimit
        ? null
        : (contextMessageLimit ?? this.contextMessageLimit),
    maxContextTokens: clearMaxContextTokens
        ? null
        : (maxContextTokens ?? this.maxContextTokens),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'displayName': displayName,
    'apiKeys': apiKeys,
    'apiBaseUrl': apiBaseUrl,
    'enabled': enabled,
    'models': models,
    'visible_models': visibleModels,
    'hidden_models': hiddenModels,
    'capabilities': capabilities,
    'custom_config': customConfig,
    'disable_tool_calling': disableToolCalling,
    if (temperature != null) 'temperature': temperature,
    if (topP != null) 'top_p': topP,
    if (contextMessageLimit != null)
      'context_message_limit': contextMessageLimit,
    if (maxContextTokens != null) 'max_context_tokens': maxContextTokens,
  };

  factory ProviderAuth.fromJson(Map<String, dynamic> json) {
    List<String> clean(Iterable<dynamic>? source) =>
        (source ?? const <dynamic>[])
            .map((e) => e is String ? e.trim() : e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList();

    final models = clean((json['models'] as List?)?.cast<dynamic>());
    final visible = clean((json['visible_models'] as List?)?.cast<dynamic>());
    final hidden = clean((json['hidden_models'] as List?)?.cast<dynamic>());
    final capabilities = clean(
      (json['capabilities'] as List?)?.cast<dynamic>(),
    );
    final customConfig =
        (json['custom_config'] as Map?)?.cast<String, dynamic>() ?? {};

    final combinedModels = <String>[
      ...models,
      ...visible.where((e) => !models.contains(e)),
      ...hidden.where((e) => !models.contains(e)),
    ];

    return ProviderAuth(
      id: (json['id'] as String?) ?? '',
      displayName: json['displayName'] as String?,
      apiKeys: clean((json['apiKeys'] as List?)?.cast<dynamic>()),
      apiBaseUrl:
          (json['apiBaseUrl'] as String?) ?? 'https://api.openai.com/v1',
      enabled: (json['enabled'] as bool?) ?? true,
      models: combinedModels,
      visibleModels: visible.isEmpty && combinedModels.isNotEmpty
          ? [combinedModels.first]
          : visible,
      hiddenModels: hidden.where((e) => !visible.contains(e)).toList(),
      capabilities: capabilities.isEmpty ? ['chat'] : capabilities,
      customConfig: customConfig,
      disableToolCalling: (json['disable_tool_calling'] as bool?) ?? false,
      temperature: (json['temperature'] as num?)?.toDouble(),
      topP: (json['top_p'] as num?)?.toDouble(),
      contextMessageLimit: json['context_message_limit'] as int?,
      maxContextTokens: json['max_context_tokens'] as int?,
    );
  }
}

/// 模型级配置项
/// 存储每个模型的覆盖配置，包括工具调用、温度等
class ModelConfig {
  /// 是否禁用工具调用，默认 false（不禁用）
  final bool disableToolCalling;

  /// 温度参数，null 表示使用全局默认值
  final double? temperature;

  /// Top P 参数，null 表示不覆盖，使用提供商默认
  final double? topP;

  /// 上下文消息数量限制，null 表示不限制，超过时自动截断
  final int? contextMessageLimit;
  final List<String>? chatCapabilities;

  /// 最大上下文 Token 数，null 表示使用硬编码表或兜底值
  final int? maxContextTokens;

  /// 模型默认思考档位，null 表示未设置（走预设 / 软件默认）
  final ThinkingLevel? thinkingLevel;

  const ModelConfig({
    this.disableToolCalling = false,
    this.temperature,
    this.topP,
    this.contextMessageLimit,
    this.chatCapabilities,
    this.maxContextTokens,
    this.thinkingLevel,
  });

  /// 是否为默认配置（全部为默认值时可删除以节省空间）
  bool get isDefault =>
      !disableToolCalling &&
      temperature == null &&
      topP == null &&
      contextMessageLimit == null &&
      chatCapabilities == null &&
      maxContextTokens == null &&
      thinkingLevel == null;

  ModelConfig copyWith({
    bool? disableToolCalling,
    double? temperature,
    bool clearTemperature = false,
    double? topP,
    bool clearTopP = false,
    int? contextMessageLimit,
    bool clearContextMessageLimit = false,
    List<String>? chatCapabilities,
    bool clearChatCapabilities = false,
    int? maxContextTokens,
    bool clearMaxContextTokens = false,
    ThinkingLevel? thinkingLevel,
    bool clearThinkingLevel = false,
  }) => ModelConfig(
    disableToolCalling: disableToolCalling ?? this.disableToolCalling,
    temperature: clearTemperature ? null : (temperature ?? this.temperature),
    topP: clearTopP ? null : (topP ?? this.topP),
    contextMessageLimit: clearContextMessageLimit
        ? null
        : (contextMessageLimit ?? this.contextMessageLimit),
    chatCapabilities: clearChatCapabilities
        ? null
        : (chatCapabilities != null
              ? ChatModelCapability.normalizeValues(chatCapabilities)
              : this.chatCapabilities),
    maxContextTokens: clearMaxContextTokens
        ? null
        : (maxContextTokens ?? this.maxContextTokens),
    thinkingLevel: clearThinkingLevel
        ? null
        : (thinkingLevel ?? this.thinkingLevel),
  );

  Map<String, dynamic> toJson() => {
    'disable_tool_calling': disableToolCalling,
    if (temperature != null) 'temperature': temperature,
    if (topP != null) 'top_p': topP,
    if (contextMessageLimit != null)
      'context_message_limit': contextMessageLimit,
    if (chatCapabilities != null) 'chat_capabilities': chatCapabilities,
    if (maxContextTokens != null) 'max_context_tokens': maxContextTokens,
    if (thinkingLevel != null) 'thinking_level': thinkingLevel!.storageValue,
  };

  factory ModelConfig.fromJson(Map<String, dynamic> json) => ModelConfig(
    disableToolCalling: (json['disable_tool_calling'] as bool?) ?? false,
    temperature: (json['temperature'] as num?)?.toDouble(),
    topP: (json['top_p'] as num?)?.toDouble(),
    contextMessageLimit: json['context_message_limit'] as int?,
    chatCapabilities: json.containsKey('chat_capabilities')
        ? ChatModelCapability.normalizeValues(
            (json['chat_capabilities'] as List? ?? const <dynamic>[]),
          )
        : null,
    maxContextTokens: json['max_context_tokens'] as int?,
    thinkingLevel: ThinkingLevel.tryParse(json['thinking_level']),
  );
}

/// 全局字体缩放上下限
const double kMinTextScaleFactor = 0.8;
const double kMaxTextScaleFactor = 1.5;

/// 全局界面缩放上下限
const double kMinUiScaleFactor = 0.85;
const double kMaxUiScaleFactor = 1.20;

/// 图片预览大小缩放上下限
const double kMinImagePreviewScale = 0.5;
const double kMaxImagePreviewScale = 1.5;

/// 桌面窗口控制按钮位置
enum WindowControlButtonSide {
  left('left', '左侧'),
  right('right', '右侧');

  const WindowControlButtonSide(this.value, this.label);
  final String value;
  final String label;

  static WindowControlButtonSide fromValue(String? value) {
    for (final side in WindowControlButtonSide.values) {
      if (side.value == value) return side;
    }
    return WindowControlButtonSide.left;
  }
}

/// 应用设置数据类
class AppSettings {
  final bool smartReplyEnabled;
  final String smartReplyModel;
  final bool ttsEnabled;
  final String defaultModelName;
  final double? temperature;
  final String defaultPersonaPrompt;
  final List<String> modelList;
  final List<String> allKnownModels;
  final Map<String, String> modelDisplayNames;

  /// 模型类型映射：modelId -> ModelType.value
  /// 只存储非 chat 类型的模型，chat 是默认值
  final Map<String, String> modelTypes;

  /// 模型级别配置映射：modelId -> ModelConfig
  /// 只存储有自定义配置的模型
  final Map<String, ModelConfig> modelConfigs;
  final String apiKey;
  final String apiBaseUrl;

  /// 全局常开：持久化读取时恒为 true；是否启用由角色/会话的插件选择决定。
  final bool imageGenerationEnabled;
  final int maxFileUploadMB;
  final int contextWindowTokens;
  final List<CustomModel> customModels;
  final List<ProviderAuth> providers;
  final Map<String, String> modelProviderMap;
  final String backendApiKey;
  final bool messageChunkingEnabled;
  final MessageFormatConfig messageFormatConfig;

  /// 全局字体缩放因子（0.8~1.5，默认 1.0）
  final double textScaleFactor;

  /// 全局界面缩放因子（0.85~1.20，默认 1.0）
  /// 作用于布局与组件大小，不仅影响文字。
  final double uiScaleFactor;

  /// 图片预览大小缩放因子（0.5~1.5，默认 1.0）
  /// 仅影响消息中的图片缩略图大小，不影响全屏预览。
  final double imagePreviewScale;

  /// Windows 桌面端仿 macOS 窗口控制按钮位置。
  final WindowControlButtonSide windowsWindowControlsSide;
  final String? userAvatar;
  final String? userName;
  final AutoReplySettings autoReplySettings;
  final GlobalBackgroundColor globalBackgroundColor;
  final ChatBackgroundColor chatBackgroundColor;
  final bool isDarkMode;
  final bool useSystemTheme;
  final String accentColor;
  final bool hideUserAvatar;

  /// 语音消息气泡是否默认展开显示文字
  final bool expandAudioText;

  /// 是否启用玻璃材质（背景模糊）效果
  final bool glassEffectEnabled;

  /// 玻璃厚度的兼容存储值（sigma）；界面与渲染映射为三个档位。
  final double glassBlurSigma;

  /// 是否使用液态玻璃材质（透镜物理折射，关闭时为常规平整毛玻璃）
  final bool useLiquidGlass;

  MoeSurfaceMaterial get surfaceMaterial => MoeSurfaceMaterial.fromFlags(
    enabled: glassEffectEnabled,
    liquid: useLiquidGlass,
  );

  /// 默认聊天模型列表（有序，第一个为首选，失败后自动轮询下一个）
  final List<String> defaultChatModels;

  /// 是否跳过视觉兼容性提示弹窗（用户勾选"不再提醒"后为 true）
  final bool skipVisionCompatDialog;
  final EnhancedDialogueSettings enhancedDialogueSettings;
  final CallFlowSettings callFlowSettings;

  /// 调试用：流式分段逐条投递延迟（秒）
  /// 0 表示关闭延迟。
  final double streamSegmentDelaySeconds;

  const AppSettings({
    this.smartReplyEnabled = false,
    this.smartReplyModel = '',
    required this.ttsEnabled,
    required this.defaultModelName,
    this.temperature,
    required this.defaultPersonaPrompt,
    required this.modelList,
    required this.allKnownModels,
    required this.modelDisplayNames,
    required this.modelTypes,
    required this.modelConfigs,
    required this.apiKey,
    required this.apiBaseUrl,
    required this.imageGenerationEnabled,
    required this.maxFileUploadMB,
    required this.contextWindowTokens,
    required this.customModels,
    required this.providers,
    required this.modelProviderMap,
    required this.backendApiKey,
    required this.messageChunkingEnabled,
    required this.messageFormatConfig,
    required this.textScaleFactor,
    required this.uiScaleFactor,
    this.imagePreviewScale = 1.0,
    this.windowsWindowControlsSide = WindowControlButtonSide.left,
    required this.autoReplySettings,
    required this.globalBackgroundColor,
    required this.chatBackgroundColor,
    required this.isDarkMode,
    required this.useSystemTheme,
    required this.accentColor,
    this.hideUserAvatar = true,
    this.expandAudioText = true,
    this.glassEffectEnabled = true,
    this.glassBlurSigma = kDefaultGlassBlurSigma,
    this.useLiquidGlass = true,
    this.defaultChatModels = const <String>[],
    this.skipVisionCompatDialog = false,
    this.enhancedDialogueSettings = const EnhancedDialogueSettings(),
    this.callFlowSettings = const CallFlowSettings(),
    this.streamSegmentDelaySeconds = 0,
    this.userAvatar,
    this.userName,
  });

  AppSettings copyWith({
    bool? smartReplyEnabled,
    String? smartReplyModel,
    bool? ttsEnabled,
    String? defaultModelName,
    double? temperature,
    String? defaultPersonaPrompt,
    List<String>? modelList,
    List<String>? allKnownModels,
    Map<String, String>? modelDisplayNames,
    Map<String, String>? modelTypes,
    Map<String, ModelConfig>? modelConfigs,
    String? apiKey,
    String? apiBaseUrl,
    bool? imageGenerationEnabled,
    int? maxFileUploadMB,
    int? contextWindowTokens,
    List<CustomModel>? customModels,
    List<ProviderAuth>? providers,
    Map<String, String>? modelProviderMap,
    String? backendApiKey,
    bool? messageChunkingEnabled,
    MessageFormatConfig? messageFormatConfig,
    double? textScaleFactor,
    double? uiScaleFactor,
    double? imagePreviewScale,
    WindowControlButtonSide? windowsWindowControlsSide,
    AutoReplySettings? autoReplySettings,
    GlobalBackgroundColor? globalBackgroundColor,
    ChatBackgroundColor? chatBackgroundColor,
    bool? isDarkMode,
    bool? useSystemTheme,
    String? accentColor,
    bool? hideUserAvatar,
    bool? expandAudioText,
    bool? glassEffectEnabled,
    double? glassBlurSigma,
    bool? useLiquidGlass,
    List<String>? defaultChatModels,
    bool? skipVisionCompatDialog,
    EnhancedDialogueSettings? enhancedDialogueSettings,
    CallFlowSettings? callFlowSettings,
    double? streamSegmentDelaySeconds,
    String? userAvatar,
    String? userName,
  }) => AppSettings(
    smartReplyEnabled: smartReplyEnabled ?? this.smartReplyEnabled,
    smartReplyModel: smartReplyModel ?? this.smartReplyModel,
    ttsEnabled: ttsEnabled ?? this.ttsEnabled,
    defaultModelName: defaultModelName ?? this.defaultModelName,
    temperature: temperature ?? this.temperature,
    defaultPersonaPrompt: defaultPersonaPrompt ?? this.defaultPersonaPrompt,
    modelList: modelList ?? this.modelList,
    allKnownModels: allKnownModels ?? this.allKnownModels,
    modelDisplayNames: modelDisplayNames ?? this.modelDisplayNames,
    modelTypes: modelTypes ?? this.modelTypes,
    modelConfigs: modelConfigs ?? this.modelConfigs,
    apiKey: apiKey ?? this.apiKey,
    apiBaseUrl: apiBaseUrl ?? this.apiBaseUrl,
    imageGenerationEnabled:
        imageGenerationEnabled ?? this.imageGenerationEnabled,
    maxFileUploadMB: maxFileUploadMB ?? this.maxFileUploadMB,
    contextWindowTokens: contextWindowTokens ?? this.contextWindowTokens,
    customModels: customModels ?? this.customModels,
    providers: providers ?? this.providers,
    modelProviderMap: modelProviderMap ?? this.modelProviderMap,
    backendApiKey: backendApiKey ?? this.backendApiKey,
    messageChunkingEnabled:
        messageChunkingEnabled ?? this.messageChunkingEnabled,
    messageFormatConfig: messageFormatConfig ?? this.messageFormatConfig,
    textScaleFactor: textScaleFactor ?? this.textScaleFactor,
    uiScaleFactor: uiScaleFactor ?? this.uiScaleFactor,
    imagePreviewScale: imagePreviewScale ?? this.imagePreviewScale,
    windowsWindowControlsSide:
        windowsWindowControlsSide ?? this.windowsWindowControlsSide,
    autoReplySettings: autoReplySettings ?? this.autoReplySettings,
    globalBackgroundColor: globalBackgroundColor ?? this.globalBackgroundColor,
    chatBackgroundColor: chatBackgroundColor ?? this.chatBackgroundColor,
    isDarkMode: isDarkMode ?? this.isDarkMode,
    useSystemTheme: useSystemTheme ?? this.useSystemTheme,
    accentColor: accentColor ?? this.accentColor,
    hideUserAvatar: hideUserAvatar ?? this.hideUserAvatar,
    expandAudioText: expandAudioText ?? this.expandAudioText,
    glassEffectEnabled: glassEffectEnabled ?? this.glassEffectEnabled,
    glassBlurSigma: glassBlurSigma ?? this.glassBlurSigma,
    useLiquidGlass: useLiquidGlass ?? this.useLiquidGlass,
    defaultChatModels: defaultChatModels ?? this.defaultChatModels,
    skipVisionCompatDialog:
        skipVisionCompatDialog ?? this.skipVisionCompatDialog,
    enhancedDialogueSettings:
        enhancedDialogueSettings ?? this.enhancedDialogueSettings,
    callFlowSettings: callFlowSettings ?? this.callFlowSettings,
    streamSegmentDelaySeconds:
        streamSegmentDelaySeconds ?? this.streamSegmentDelaySeconds,
    userAvatar: userAvatar ?? this.userAvatar,
    userName: userName ?? this.userName,
  );

  bool _isKnownProviderId(String providerId) {
    for (final provider in providers) {
      if (provider.id == providerId) return true;
    }
    return false;
  }

  /// 从模型引用中提取原始模型 ID。
  ///
  /// 支持两种格式：
  /// 1) 旧格式：`gpt-4o`
  /// 2) 新格式：`provider:gpt-4o`
  String getRawModelId(String modelRef) {
    final ref = modelRef.trim();
    if (ref.isEmpty) return ref;
    final idx = ref.indexOf(':');
    if (idx <= 0 || idx >= ref.length - 1) {
      return ref;
    }
    final providerId = ref.substring(0, idx).trim();
    if (!_isKnownProviderId(providerId)) {
      return ref;
    }
    return ref.substring(idx + 1).trim();
  }

  /// 获取模型引用对应的 providerId。
  ///
  /// 对于新格式优先解析前缀；旧格式回退到 `modelProviderMap`。
  String? getModelProviderId(String modelRef) {
    final ref = modelRef.trim();
    if (ref.isEmpty) return null;

    final idx = ref.indexOf(':');
    if (idx > 0 && idx < ref.length - 1) {
      final providerId = ref.substring(0, idx).trim();
      if (_isKnownProviderId(providerId)) {
        return providerId;
      }
    }

    final rawId = getRawModelId(ref);
    return modelProviderMap[ref] ?? modelProviderMap[rawId];
  }

  /// 组装 provider 维度唯一模型引用：`provider:model`。
  String buildModelRef(String providerId, String modelId) {
    final pid = providerId.trim();
    final rawId = getRawModelId(modelId);
    if (pid.isEmpty) return rawId;
    return '$pid:$rawId';
  }

  /// 转为请求层使用的 `provider:model` 形式，未知 provider 时使用 fallback。
  String toModelFullId(String modelRef, {String fallbackProvider = 'openai'}) {
    final rawId = getRawModelId(modelRef);
    final providerId = getModelProviderId(modelRef) ?? fallbackProvider;
    return '$providerId:$rawId';
  }

  String getModelDisplayName(String modelId) {
    final ref = modelId.trim();
    if (ref.isEmpty) return ref;

    final direct = modelDisplayNames[ref];
    if (direct != null && direct.trim().isNotEmpty) {
      return direct;
    }

    final rawId = getRawModelId(ref);
    final raw = modelDisplayNames[rawId];
    if (raw != null && raw.trim().isNotEmpty) {
      return raw;
    }

    return rawId;
  }

  ProviderAuth? getProvider(String providerId) {
    final normalized = providerId.trim();
    if (normalized.isEmpty) return null;
    for (final provider in providers) {
      if (provider.id == normalized) return provider;
    }
    return null;
  }

  List<String> getProviderModelsByType(String providerId, {ModelType? type}) {
    final provider = getProvider(providerId);
    if (provider == null || !provider.enabled) {
      return const <String>[];
    }

    final result = <String>[];
    for (final model in provider.models) {
      final modelRef = buildModelRef(provider.id, model);
      if (type != null && getModelType(modelRef) != type) {
        continue;
      }
      if (!result.contains(model)) {
        result.add(model);
      }
    }
    return result;
  }

  List<String> getProviderVisibleModelsByType(
    String providerId, {
    ModelType? type,
  }) {
    final provider = getProvider(providerId);
    if (provider == null || !provider.enabled) {
      return const <String>[];
    }

    final result = <String>[];
    for (final model in provider.visibleModels) {
      final modelRef = buildModelRef(provider.id, model);
      if (type != null && getModelType(modelRef) != type) {
        continue;
      }
      if (!result.contains(model)) {
        result.add(model);
      }
    }
    return result;
  }

  bool providerHasModelType(String providerId, ModelType type) {
    return getProviderModelsByType(providerId, type: type).isNotEmpty;
  }

  /// 获取模型类型（优先使用用户设置，否则自动推断）
  ModelType getModelType(String modelId) {
    final ref = modelId.trim();
    final rawId = getRawModelId(ref);
    final stored = modelTypes[ref] ?? modelTypes[rawId];
    if (stored != null) {
      return ModelType.fromValue(stored);
    }
    return ModelType.inferFromModelId(rawId);
  }

  /// 获取模型配置（如果没有自定义配置，返回默认配置）
  ModelConfig getModelConfig(String modelId) {
    final ref = modelId.trim();
    final rawId = getRawModelId(ref);
    return modelConfigs[ref] ?? modelConfigs[rawId] ?? const ModelConfig();
  }

  /// 检查模型是否禁用工具调用
  /// 获取对话模型能力（支持手动覆盖）
  List<ChatModelCapability> getChatModelCapabilities(String modelId) {
    if (getModelType(modelId) != ModelType.chat) {
      return const <ChatModelCapability>[];
    }

    final config = getModelConfig(modelId);
    if (config.chatCapabilities != null) {
      return ChatModelCapability.fromValues(config.chatCapabilities);
    }

    final rawId = getRawModelId(modelId);
    return inferChatModelCapabilities(rawId);
  }

  bool hasChatModelCapability(String modelId, ChatModelCapability capability) {
    return getChatModelCapabilities(modelId).contains(capability);
  }

  EffectiveImageGenerationRoute resolveEffectiveImageGenerationRoute(
    String modelId,
  ) {
    if (callFlowSettings.mode == CallFlowMode.fast) {
      return EffectiveImageGenerationRoute.fast;
    }
    final supportsVision = hasChatModelCapability(
      modelId,
      ChatModelCapability.vision,
    );
    final supportsToolCalling =
        hasChatModelCapability(modelId, ChatModelCapability.tools) &&
        !isModelToolCallingDisabled(modelId);
    return supportsVision && supportsToolCalling
        ? EffectiveImageGenerationRoute.stable
        : EffectiveImageGenerationRoute.fast;
  }

  bool shouldUseStableImageGenerationRoute(String modelId) {
    return resolveEffectiveImageGenerationRoute(modelId) ==
        EffectiveImageGenerationRoute.stable;
  }

  bool shouldUseFastImageGenerationRoute(String modelId) {
    return resolveEffectiveImageGenerationRoute(modelId) ==
        EffectiveImageGenerationRoute.fast;
  }

  /// 检查模型是否禁用工具调用
  bool isModelToolCallingDisabled(String modelId) {
    return getModelConfig(modelId).disableToolCalling;
  }

  /// 获取模型的最大上下文 Token 数（优先用户配置 > 硬编码表 > 128K 兜底）
  int getMaxContextTokens(String modelId) {
    // 1. 模型级别配置
    final modelConfig = getModelConfig(modelId);
    if (modelConfig.maxContextTokens != null) {
      return modelConfig.maxContextTokens!;
    }
    // 2. Provider 级别配置
    final providerId = getModelProviderId(modelId);
    if (providerId != null) {
      final provider = getProvider(providerId);
      if (provider?.maxContextTokens != null) {
        return provider!.maxContextTokens!;
      }
    }
    // 3. 回退到硬编码表
    final rawId = getRawModelId(modelId);
    return getModelContextLimit(rawId);
  }
}
