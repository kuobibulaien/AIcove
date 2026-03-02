/// 设置相关数据模型
///
/// 从 app_settings.dart 提取，包含枚举类型和数据类。
///
/// 更新记录：
/// - 2025-12-31: 从 app_settings.dart 提取
library;

import 'package:flutter/material.dart';
import '../../core/utils/message_formatter.dart';

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
    final id = modelId.toLowerCase();

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

// TTS 模型匹配规则
final _ttsPatterns = RegExp(
  r'\b('
  r'tts|'
  r'text-to-speech|'
  r'speech-synthesis|'
  r'alloy|' // OpenAI TTS voices
  r'echo|'
  r'fable|'
  r'onyx|'
  r'nova|'
  r'shimmer|'
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
  final int dailyLimit;
  final int minIntervalMinutes;
  final bool quietHoursEnabled;
  final String quietHoursStart;
  final String quietHoursEnd;
  final bool allowExactAlarm;
  final String analyzerPrompt;
  final String? analyzerModel;
  final String? analyzerProvider;

  static const String defaultAnalyzerPrompt =
      '''You are the "Scheduler" for an AI girlfriend. Your job is to analyze the chat history and ORGANIZE the trigger list.

You will receive:
1. Current conversation history
2. Existing pending triggers (if any)

Your task is to return the COMPLETE list of triggers that should exist going forward. This means:
- KEEP triggers that are still relevant
- ADD new triggers based on recent conversation
- REMOVE triggers that are no longer appropriate or duplicate

Rules:
1. Look for cues in conversation:
   - User going to sleep -> "Good morning" trigger (delay: 420 min, allow_night: false)
   - User going to work -> "Lunch break check-in" trigger (delay: 240 min)
   - User watching movie -> "How was the movie?" trigger (delay: 120 min)
   - User mentions future event -> Trigger for that time

2. Clean up outdated triggers:
   - If user says "actually I'm not sleeping", remove the "Good morning" trigger
   - If there are duplicate triggers with similar purpose, keep only one
   - If context has changed making a trigger irrelevant, remove it

3. Return format (strictly JSON array):
[
  {
    "id": "existing-trigger-id-to-keep",  // Optional: if keeping existing trigger
    "title": "Description of why this trigger exists",
    "delay_minutes": 60,
    "allow_night": false
  }
]

If no triggers should exist, return [].
Do not output markdown. Just JSON.''';

  const AutoReplySettings({
    this.enabled = false,
    this.dailyLimit = 3,
    this.minIntervalMinutes = 120,
    this.quietHoursEnabled = true,
    this.quietHoursStart = '22:00',
    this.quietHoursEnd = '08:00',
    this.allowExactAlarm = false,
    this.analyzerPrompt = defaultAnalyzerPrompt,
    this.analyzerModel,
    this.analyzerProvider,
  });

  AutoReplySettings copyWith({
    bool? enabled,
    int? dailyLimit,
    int? minIntervalMinutes,
    bool? quietHoursEnabled,
    String? quietHoursStart,
    String? quietHoursEnd,
    bool? allowExactAlarm,
    String? analyzerPrompt,
    String? analyzerModel,
    String? analyzerProvider,
    bool clearAnalyzerModel = false,
    bool clearAnalyzerProvider = false,
  }) {
    return AutoReplySettings(
      enabled: enabled ?? this.enabled,
      dailyLimit: dailyLimit ?? this.dailyLimit,
      minIntervalMinutes: minIntervalMinutes ?? this.minIntervalMinutes,
      quietHoursEnabled: quietHoursEnabled ?? this.quietHoursEnabled,
      quietHoursStart: quietHoursStart ?? this.quietHoursStart,
      quietHoursEnd: quietHoursEnd ?? this.quietHoursEnd,
      allowExactAlarm: allowExactAlarm ?? this.allowExactAlarm,
      analyzerPrompt: analyzerPrompt ?? this.analyzerPrompt,
      analyzerModel:
          clearAnalyzerModel ? null : (analyzerModel ?? this.analyzerModel),
      analyzerProvider: clearAnalyzerProvider
          ? null
          : (analyzerProvider ?? this.analyzerProvider),
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'daily_limit': dailyLimit,
        'min_interval_minutes': minIntervalMinutes,
        'quiet_hours_enabled': quietHoursEnabled,
        'quiet_hours_start': quietHoursStart,
        'quiet_hours_end': quietHoursEnd,
        'allow_exact_alarm': allowExactAlarm,
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

    return AutoReplySettings(
      enabled: json['enabled'] == true,
      dailyLimit: clampInt(json['daily_limit'] as num?, 1, 10, 3),
      minIntervalMinutes:
          clampInt(json['min_interval_minutes'] as num?, 15, 720, 120),
      quietHoursEnabled: json['quiet_hours_enabled'] != false,
      quietHoursStart:
          normalizeTime(json['quiet_hours_start'] as String?, '22:00'),
      quietHoursEnd: normalizeTime(json['quiet_hours_end'] as String?, '08:00'),
      allowExactAlarm: json['allow_exact_alarm'] == true,
      analyzerPrompt: (json['analyzer_prompt'] as String?)?.isEmpty == false
          ? json['analyzer_prompt'] as String
          : defaultAnalyzerPrompt,
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
      '''你是“增强对话助手”。你的任务是基于给定的人设与最近对话，生成一条可以直接回复用户的消息，帮助当前会话回到原始人设。

要求：
1. 只输出可直接发送给用户的一段回复，不解释你的推理过程
2. 保持口吻与原人设一致
3. 如需调用工具（如绘图/语音），可正常调用''';

  static const String defaultBootstrapUserMessage =
      '请输出本轮最终回复，并使用 <enhance>...</enhance> 包裹最终文本。';

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
  stable('stable', '稳定模式'),
  fast('fast', '快速模式');

  const CallFlowMode(this.value, this.label);
  final String value;
  final String label;

  static CallFlowMode fromValue(String? value) {
    for (final mode in CallFlowMode.values) {
      if (mode.value == value) return mode;
    }
    return CallFlowMode.stable;
  }
}

/// 调用流程设置（调试工具）
class CallFlowSettings {
  static const int minModelTimeoutSeconds = 10;
  static const int maxModelTimeoutSeconds = 300;
  static const int minToolTimeoutSeconds = 1;
  static const int maxToolTimeoutSeconds = 120;

  final CallFlowMode mode;
  final int modelTimeoutSeconds;
  final int toolTimeoutSeconds;

  const CallFlowSettings({
    this.mode = CallFlowMode.stable,
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
      modelTimeoutSeconds:
          (modelTimeoutSeconds ?? this.modelTimeoutSeconds).clamp(
        minModelTimeoutSeconds,
        maxModelTimeoutSeconds,
      ),
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
        apiBaseUrl:
            (json['apiBaseUrl'] as String?) ?? 'https://api.openai.com/v1',
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
  final String modelType;

  /// 是否禁用工具调用，默认 false（即默认启用工具调用）
  final bool disableToolCalling;

  /// 温度参数，null 表示使用全局默认值
  final double? temperature;

  /// Top P 参数，null 表示不覆盖，使用提供商默认
  final double? topP;

  /// 上下文消息数量限制，null 表示不限制，超过时自动截断
  final int? contextMessageLimit;

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
    this.modelType = 'chat',
    this.disableToolCalling = false,
    this.temperature,
    this.topP,
    this.contextMessageLimit,
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
    String? modelType,
    bool? disableToolCalling,
    double? temperature,
    double? topP,
    int? contextMessageLimit,
    bool clearTemperature = false,
    bool clearTopP = false,
    bool clearContextMessageLimit = false,
  }) =>
      ProviderAuth(
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
        modelType: modelType ?? this.modelType,
        disableToolCalling: disableToolCalling ?? this.disableToolCalling,
        temperature:
            clearTemperature ? null : (temperature ?? this.temperature),
        topP: clearTopP ? null : (topP ?? this.topP),
        contextMessageLimit: clearContextMessageLimit
            ? null
            : (contextMessageLimit ?? this.contextMessageLimit),
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
        'model_type': modelType,
        'disable_tool_calling': disableToolCalling,
        if (temperature != null) 'temperature': temperature,
        if (topP != null) 'top_p': topP,
        if (contextMessageLimit != null)
          'context_message_limit': contextMessageLimit,
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
    final capabilities =
        clean((json['capabilities'] as List?)?.cast<dynamic>());
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
      modelType: (json['model_type'] as String?) ?? 'chat',
      disableToolCalling: (json['disable_tool_calling'] as bool?) ?? false,
      temperature: (json['temperature'] as num?)?.toDouble(),
      topP: (json['top_p'] as num?)?.toDouble(),
      contextMessageLimit: json['context_message_limit'] as int?,
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

  const ModelConfig({
    this.disableToolCalling = false,
    this.temperature,
    this.topP,
    this.contextMessageLimit,
    this.chatCapabilities,
  });

  /// 是否为默认配置（全部为默认值时可删除以节省空间）
  bool get isDefault =>
      !disableToolCalling &&
      temperature == null &&
      topP == null &&
      contextMessageLimit == null &&
      chatCapabilities == null;

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
  }) =>
      ModelConfig(
        disableToolCalling: disableToolCalling ?? this.disableToolCalling,
        temperature:
            clearTemperature ? null : (temperature ?? this.temperature),
        topP: clearTopP ? null : (topP ?? this.topP),
        contextMessageLimit: clearContextMessageLimit
            ? null
            : (contextMessageLimit ?? this.contextMessageLimit),
        chatCapabilities: clearChatCapabilities
            ? null
            : (chatCapabilities != null
                ? ChatModelCapability.normalizeValues(chatCapabilities)
                : this.chatCapabilities),
      );

  Map<String, dynamic> toJson() => {
        'disable_tool_calling': disableToolCalling,
        if (temperature != null) 'temperature': temperature,
        if (topP != null) 'top_p': topP,
        if (contextMessageLimit != null)
          'context_message_limit': contextMessageLimit,
        if (chatCapabilities != null) 'chat_capabilities': chatCapabilities,
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

/// 应用设置数据类
class AppSettings {
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
  final bool imageGenerationEnabled;
  final int maxFileUploadMB;
  final int historyMessageLimit;
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
  final String? userAvatar;
  final String? userName;
  final AutoReplySettings autoReplySettings;
  final GlobalBackgroundColor globalBackgroundColor;
  final ChatBackgroundColor chatBackgroundColor;
  final bool isDarkMode;
  final bool useSystemTheme;
  final String accentColor;
  final bool hideUserAvatar;

  /// 默认聊天模型列表（有序，第一个为首选，失败后自动轮询下一个）
  final List<String> defaultChatModels;

  /// 默认图片识别模型（单选，用于 sendWithImage）
  final String? defaultVisionModel;

  /// 图片发送时是否优先走视觉辅助模型
  final bool preferVisionAssistant;

  /// 是否跳过视觉兼容性提示弹窗（用户勾选"不再提醒"后为 true）
  final bool skipVisionCompatDialog;
  final EnhancedDialogueSettings enhancedDialogueSettings;
  final CallFlowSettings callFlowSettings;

  /// 调试用：流式分段逐条投递延迟（秒）
  /// 0 表示关闭延迟。
  final double streamSegmentDelaySeconds;

  const AppSettings({
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
    required this.historyMessageLimit,
    required this.customModels,
    required this.providers,
    required this.modelProviderMap,
    required this.backendApiKey,
    required this.messageChunkingEnabled,
    required this.messageFormatConfig,
    required this.textScaleFactor,
    required this.uiScaleFactor,
    this.imagePreviewScale = 1.0,
    required this.autoReplySettings,
    required this.globalBackgroundColor,
    required this.chatBackgroundColor,
    required this.isDarkMode,
    required this.useSystemTheme,
    required this.accentColor,
    this.hideUserAvatar = true,
    this.defaultChatModels = const <String>[],
    this.defaultVisionModel,
    this.preferVisionAssistant = false,
    this.skipVisionCompatDialog = false,
    this.enhancedDialogueSettings = const EnhancedDialogueSettings(),
    this.callFlowSettings = const CallFlowSettings(),
    this.streamSegmentDelaySeconds = 0,
    this.userAvatar,
    this.userName,
  });

  AppSettings copyWith({
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
    int? historyMessageLimit,
    List<CustomModel>? customModels,
    List<ProviderAuth>? providers,
    Map<String, String>? modelProviderMap,
    String? backendApiKey,
    bool? messageChunkingEnabled,
    MessageFormatConfig? messageFormatConfig,
    double? textScaleFactor,
    double? uiScaleFactor,
    double? imagePreviewScale,
    AutoReplySettings? autoReplySettings,
    GlobalBackgroundColor? globalBackgroundColor,
    ChatBackgroundColor? chatBackgroundColor,
    bool? isDarkMode,
    bool? useSystemTheme,
    String? accentColor,
    bool? hideUserAvatar,
    List<String>? defaultChatModels,
    String? defaultVisionModel,
    bool? preferVisionAssistant,
    bool? skipVisionCompatDialog,
    EnhancedDialogueSettings? enhancedDialogueSettings,
    CallFlowSettings? callFlowSettings,
    double? streamSegmentDelaySeconds,
    String? userAvatar,
    String? userName,
  }) =>
      AppSettings(
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
        historyMessageLimit: historyMessageLimit ?? this.historyMessageLimit,
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
        autoReplySettings: autoReplySettings ?? this.autoReplySettings,
        globalBackgroundColor:
            globalBackgroundColor ?? this.globalBackgroundColor,
        chatBackgroundColor: chatBackgroundColor ?? this.chatBackgroundColor,
        isDarkMode: isDarkMode ?? this.isDarkMode,
        useSystemTheme: useSystemTheme ?? this.useSystemTheme,
        accentColor: accentColor ?? this.accentColor,
        hideUserAvatar: hideUserAvatar ?? this.hideUserAvatar,
        defaultChatModels: defaultChatModels ?? this.defaultChatModels,
        defaultVisionModel: defaultVisionModel ?? this.defaultVisionModel,
        preferVisionAssistant:
            preferVisionAssistant ?? this.preferVisionAssistant,
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

  /// 检查模型是否禁用工具调用
  bool isModelToolCallingDisabled(String modelId) {
    return getModelConfig(modelId).disableToolCalling;
  }
}
