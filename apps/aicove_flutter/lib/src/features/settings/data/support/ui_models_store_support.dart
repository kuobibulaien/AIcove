import '../../settings_models.dart';
import '../../../../core/api/providers/google_api_mode.dart';
import '../../../../core/api/providers/provider_adapter_factory.dart';
import '../../../../core/api/providers/zai_compat.dart';
import '../../../../core/prompts/prompt_builtin_defaults.g.dart';

/// SharedPreferences 键名，统一管理模型与渠道配置。
const kUiModelsStoreKey = 'aicove.ui_models.v1';
const kUiModelsLegacyStoreKeys = <String>[
  // Historical key used by older app naming.
  'mygril.ui_models.v1',
];

/// NovelAI 文生图生产模型 ID。
/// NovelAI 没有稳定的图片模型列表端点，目录随客户端版本受控维护；
/// 顺序同时表达默认优先级：New（V5）在前，Legacy 在后。
const kNovelAiV5FullModelId = 'nai-diffusion-5-full';

const kNovelAiDefaultModels = <String>[
  kNovelAiV5FullModelId,
  'nai-diffusion-5-curated',
  'nai-diffusion-4-5-full',
  'nai-diffusion-4-5-curated',
  'nai-diffusion-4-full',
  'nai-diffusion-4-curated-preview',
  'nai-diffusion-3',
  'nai-diffusion-furry-3',
];

/// 既有 NovelAI 渠道升级到 V5 Full 默认模型的一次性迁移 id。
const kNovelAiV5FullDefaultMigrationId = 'novelai_v5_full_default_20260821';

/// 追加内置 Fish Audio 渠道的迁移 id。
const kFishAudioProviderBackfillMigrationId =
    'builtin_provider_fish_audio_20260904';

const _novelAiModelAliases = <String, String>{
  // Older local presets used this id, but NovelAI now expects "curated".
  'nai-diffusion-4-5-curated-preview': 'nai-diffusion-4-5-curated',
};

/// 数据存储的默认结构（KISS：只保留最小必要字段）。
/// 首次初始化时提供 DeepSeek 测试配置，删除后不再自动恢复。
/// API Key 从 assets/local_keys.json 读取，不硬编码在代码中。
Map<String, dynamic> buildDefaultUiModelsStoreData() => <String, dynamic>{
  'providers': [
    {
      'id': 'deepseek',
      'displayName': 'DeepSeek',
      'apiKeys': <String>[],
      'apiBaseUrl': 'https://api.deepseek.com/v1',
      'enabled': true,
      'models': <String>['deepseek-reasoner', 'deepseek-chat'],
      'visible_models': <String>['deepseek-reasoner', 'deepseek-chat'],
      'hidden_models': <String>[],
      'capabilities': <String>['chat'],
    },
    {
      'id': 'openrouter',
      'displayName': 'OpenRouter',
      'apiKeys': <String>[],
      'apiBaseUrl': 'https://openrouter.ai/api/v1',
      'enabled': false,
      'models': <String>[],
      'visible_models': <String>[],
      'hidden_models': <String>[],
      'capabilities': <String>['chat'],
    },
    {
      'id': 'minimax',
      'displayName': 'MiniMax',
      'apiKeys': <String>[],
      'apiBaseUrl': 'https://api.minimaxi.com/v1',
      'enabled': true,
      'models': <String>[
        'speech-2.8-hd',
        'speech-2.8-turbo',
        'speech-2.6-hd',
        'speech-2.6-turbo',
        'speech-02-hd',
        'speech-02-turbo',
      ],
      'visible_models': <String>['speech-2.8-hd', 'speech-2.8-turbo'],
      'hidden_models': <String>[],
      'capabilities': <String>['tts'],
    },
    {
      'id': 'kimi',
      'displayName': 'Kimi',
      'apiKeys': <String>[],
      'apiBaseUrl': 'https://api.moonshot.cn/v1',
      'enabled': true,
      'models': <String>[],
      'visible_models': <String>[],
      'hidden_models': <String>[],
      'capabilities': <String>['chat'],
    },
    {
      'id': 'aliyun',
      'displayName': '阿里云',
      'apiKeys': <String>[],
      'apiBaseUrl': 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      'enabled': true,
      'models': <String>[
        'cosyvoice-v3-plus',
        'qwen3-tts-vc-realtime-2026-01-15',
      ],
      'visible_models': <String>[
        'cosyvoice-v3-plus',
        'qwen3-tts-vc-realtime-2026-01-15',
      ],
      'hidden_models': <String>[],
      'capabilities': <String>['tts'],
    },
    {
      'id': 'fish_audio',
      'displayName': 'Fish Audio',
      'apiKeys': <String>[],
      'apiBaseUrl': 'https://api.fish.audio/v1',
      'enabled': false,
      'models': <String>['s2.1-pro-free', 's2.1-pro'],
      'visible_models': <String>['s2.1-pro-free', 's2.1-pro'],
      'hidden_models': <String>[],
      'capabilities': <String>['tts'],
      'custom_config': <String, dynamic>{'requestFormat': 'fish_audio'},
    },
    {
      'id': 'novelai',
      'displayName': 'NovelAI',
      'apiKeys': <String>[],
      'apiBaseUrl': 'https://image.novelai.net',
      'enabled': false,
      'models': List<String>.from(kNovelAiDefaultModels),
      'visible_models': <String>[
        kNovelAiV5FullModelId,
        'nai-diffusion-5-curated',
      ],
      'hidden_models': <String>[],
      'capabilities': <String>['image'],
      'custom_config': <String, dynamic>{
        'requestFormat': 'novelai',
        'defaultImageModel': kNovelAiV5FullModelId,
      },
    },
    {
      'id': 'siliconflow',
      'displayName': '硅基流动',
      'apiKeys': <String>[],
      'apiBaseUrl': 'https://api.siliconflow.cn/v1',
      'enabled': false,
      'models': <String>[],
      'visible_models': <String>[],
      'hidden_models': <String>[],
      'capabilities': <String>['chat'],
    },
    {
      'id': 'gemini',
      'displayName': kGoogleGeminiProviderDisplayName,
      'apiKeys': <String>[],
      'apiBaseUrl': kGeminiDeveloperApiBase,
      'enabled': false,
      'models': List<String>.from(kGeminiDeveloperDefaultModels),
      'visible_models': <String>[
        'gemini-2.5-flash',
        'gemini-2.5-pro',
        'gemini-2.5-flash-lite',
      ],
      'hidden_models': <String>[
        'gemini-2.0-flash',
        'gemini-2.0-flash-lite',
        'gemini-3-flash-preview',
      ],
      'capabilities': <String>['chat'],
      'custom_config': <String, dynamic>{'requestFormat': 'gemini'},
    },
    {
      'id': 'zai',
      'displayName': 'Z.AI',
      'apiKeys': <String>[],
      'apiBaseUrl': kZaiGeneralApiBase,
      'enabled': false,
      'models': List<String>.from(kZaiDefaultChatModels),
      'visible_models': <String>['glm-5', 'glm-5-turbo', 'glm-4.7'],
      'hidden_models': <String>[
        'glm-4.7-flash',
        'glm-4.7-flashx',
        'glm-4.6',
        'glm-4.5',
        'glm-4.5-air',
      ],
      'capabilities': <String>['chat'],
      'custom_config': <String, dynamic>{'requestFormat': 'openai'},
    },
    {
      'id': 'volcengine',
      'displayName': '火山引擎',
      'apiKeys': <String>[],
      'apiBaseUrl': 'https://ark.cn-beijing.volces.com/api/v3',
      'enabled': false,
      'models': <String>[],
      'visible_models': <String>[],
      'hidden_models': <String>[],
      'capabilities': <String>['chat'],
    },
  ],
  'visible_models': <String>['deepseek-reasoner', 'deepseek-chat'],
  'default_model': 'deepseek-reasoner',
  'model_display_names': <String, String>{
    'deepseek-chat': 'DeepSeek Chat',
    'deepseek-reasoner': 'DeepSeek Reasoner',
  },
  'backend_api_key': '',
  'applied_migrations': <String>[
    kZaiProviderBackfillMigrationId,
    kNovelAiV5FullDefaultMigrationId,
    kFishAudioProviderBackfillMigrationId,
  ],
  'image_generation_enabled': true,
  'context_window_tokens': 272000,
  'message_chunking_enabled': false,
  'message_format_config': null,
  'stream_segment_delay_seconds': 0.0,
  'text_scale_factor': 1.0,
  'ui_scale_factor': 1.0,
  'windows_window_controls_side': WindowControlButtonSide.left.value,
  'auto_reply_settings': _defaultAutoReplySettings(),
  'enhanced_dialogue_settings': _defaultEnhancedDialogueSettings(),
  'call_flow_settings': _defaultCallFlowSettings(),
  'chat_background_color': 'default',
  'is_dark_mode': false,
  'use_system_theme': true,
  'hide_user_avatar': true,
  'expand_audio_text': true,
  'user_avatar': null,
  'user_name': null,
  'skip_vision_compat_dialog': false,
};

Map<String, dynamic> _defaultAutoReplySettings() => <String, dynamic>{
  'enabled': false,
  'guard_mode_enabled': false,
  'daily_limit': 3,
  'min_interval_minutes': 120,
  'quiet_hours_enabled': true,
  'quiet_hours_start': '22:00',
  'quiet_hours_end': '08:00',
  'allow_exact_alarm': false,
  'allow_ai_set_reminders': true,
  'analyzer_prompt': AutoReplySettings.defaultAnalyzerPrompt,
  'analyzer_model': null,
  'analyzer_provider': null,
};

Map<String, dynamic> _defaultEnhancedDialogueSettings() => <String, dynamic>{
  'enabled': false,
  'system_prompt': PromptBuiltinDefaults.enhancedDialogueSystemDefault,
  'bootstrap_user_message':
      PromptBuiltinDefaults.enhancedDialogueBootstrapUserDefault,
  'recent_rounds': 3,
};

Map<String, dynamic> _defaultCallFlowSettings() => <String, dynamic>{
  'mode': 'auto',
  'model_timeout_seconds': 120,
  'tool_timeout_seconds': 30,
};

bool isNovelAiProvider({
  required String providerId,
  required String apiBaseUrl,
}) {
  final id = providerId.toLowerCase().trim();
  if (id == 'novelai' || id == 'nai') {
    return true;
  }
  return apiBaseUrl.toLowerCase().contains('novelai.net');
}

String normalizeNovelAiBaseUrl(String apiBaseUrl) {
  final trimmed = apiBaseUrl.trim();
  if (trimmed.isEmpty) return 'https://image.novelai.net';
  if (trimmed.toLowerCase().startsWith('https://api.novelai.net')) {
    return 'https://image.novelai.net${trimmed.substring('https://api.novelai.net'.length)}';
  }
  try {
    final uri = Uri.parse(trimmed);
    if (uri.host.toLowerCase() == 'api.novelai.net') {
      return uri.replace(host: 'image.novelai.net').toString();
    }
  } catch (_) {}
  return trimmed;
}

String normalizeNovelAiModelId(String modelId) {
  final trimmed = modelId.trim();
  if (trimmed.isEmpty) return trimmed;
  return _novelAiModelAliases[trimmed] ?? trimmed;
}

/// 受控目录优先：目录内模型按目录顺序前置，未知模型保持原顺序追加。
/// NovelAI 目录顺序表达默认优先级，通用字母排序会破坏它，禁止对
/// NovelAI 模型使用字母排序。
List<String> normalizeNovelAiModels(Iterable<String> models) {
  final fixed = <String>[];
  for (final model in models) {
    final normalized = normalizeNovelAiModelId(model);
    if (normalized.isEmpty || fixed.contains(normalized)) continue;
    fixed.add(normalized);
  }
  final result = <String>[];
  for (final catalog in kNovelAiDefaultModels) {
    if (fixed.contains(catalog)) result.add(catalog);
  }
  for (final model in fixed) {
    if (!kNovelAiDefaultModels.contains(model)) result.add(model);
  }
  return result;
}

/// 仅做确定性别名规范化与去重，保持原有顺序（用于可见/隐藏等用户顺序）。
List<String> normalizeNovelAiModelIds(Iterable<String> models) {
  final normalized = <String>[];
  for (final model in models) {
    final fixed = normalizeNovelAiModelId(model);
    if (fixed.isEmpty || normalized.contains(fixed)) continue;
    normalized.add(fixed);
  }
  return normalized;
}

/// NovelAI V5 Full 默认模型一次性迁移（通过 `applied_migrations` 保证幂等）。
///
/// 对每个被识别为 NovelAI 的 provider（id / base URL / requestFormat）：
/// - 受控目录前置合并进模型列表，未知模型保持原顺序；
/// - V5 Full 放到可见模型首位，保留其余可见值；
/// - 默认值缺失或属于历史内置默认（V4.5 Curated / V4.5 Full / 旧
///   V4.5 Curated Preview 别名）时升级为 V5 Full；明确的 V3、Furry V3、
///   V4 与未知自定义默认值保持原样；
/// - Token、base URL、启用状态、capabilities 与未知 custom_config 字段不变。
bool applyNovelAiV5FullDefaultMigration(Map<String, dynamic> data) {
  final applied = cleanSettingsStrings(data['applied_migrations']);
  if (applied.contains(kNovelAiV5FullDefaultMigrationId)) return false;
  applied.add(kNovelAiV5FullDefaultMigrationId);
  data['applied_migrations'] = applied;

  final providers = data['providers'];
  if (providers is! List) return true;

  for (var index = 0; index < providers.length; index += 1) {
    final entry = providers[index];
    if (entry is! Map) continue;
    final provider = Map<String, dynamic>.from(entry.cast<String, dynamic>());
    final id = (provider['id'] as String? ?? '').trim();
    final apiBaseUrl = (provider['apiBaseUrl'] as String? ?? '').trim();
    final customConfig = provider['custom_config'] is Map
        ? Map<String, dynamic>.from(
            provider['custom_config'] as Map<dynamic, dynamic>,
          )
        : <String, dynamic>{};
    final requestFormat = customConfig['requestFormat']
        ?.toString()
        .trim()
        .toLowerCase();
    final isNovelAi =
        isNovelAiProvider(providerId: id, apiBaseUrl: apiBaseUrl) ||
        requestFormat == 'novelai' ||
        requestFormat == 'nai';
    if (!isNovelAi) continue;

    // 受控目录前置合并，未知模型保持原顺序；可见但未在模型列表中的模型也保留。
    final currentDefault =
        customConfig['defaultImageModel']?.toString().trim() ?? '';
    final normalizedDefault = normalizeNovelAiModelId(currentDefault);
    final models = cleanSettingsStrings(provider['models']);
    final merged = <String>[...kNovelAiDefaultModels];
    for (final model in models) {
      final fixed = normalizeNovelAiModelId(model);
      if (fixed.isEmpty || merged.contains(fixed)) continue;
      merged.add(fixed);
    }
    for (final model in cleanSettingsStrings(provider['visible_models'])) {
      final fixed = normalizeNovelAiModelId(model);
      if (fixed.isEmpty || merged.contains(fixed)) continue;
      merged.add(fixed);
    }
    if (normalizedDefault.isNotEmpty && !merged.contains(normalizedDefault)) {
      merged.add(normalizedDefault);
    }
    provider['models'] = merged;

    final isHistoricalDefault =
        normalizedDefault.isEmpty ||
        normalizedDefault == 'nai-diffusion-4-5-curated' ||
        normalizedDefault == 'nai-diffusion-4-5-full';

    // V5 Full 放到可见模型首位，保留其余可见值。
    final visible = cleanSettingsStrings(provider['visible_models']);
    final visibleFixed = <String>[kNovelAiV5FullModelId];
    // 非历史显式默认必须继续可被运行时选中；运行时只从可见图片模型中
    // 接受 defaultImageModel，不能只保留配置字符串。
    if (!isHistoricalDefault && normalizedDefault.isNotEmpty) {
      visibleFixed.add(normalizedDefault);
    }
    for (final model in visible) {
      final fixed = normalizeNovelAiModelId(model);
      if (fixed.isEmpty || visibleFixed.contains(fixed)) continue;
      visibleFixed.add(fixed);
    }
    provider['visible_models'] = visibleFixed;

    // 缺失或历史内置默认值升级为 V5 Full；明确选择保持原样。
    if (isHistoricalDefault) {
      customConfig['defaultImageModel'] = kNovelAiV5FullModelId;
    }
    provider['custom_config'] = customConfig;
    providers[index] = provider;
  }
  return true;
}

List<String> cleanSettingsStrings(dynamic source) {
  final result = <String>[];
  if (source is Iterable) {
    for (final item in source) {
      final value = item?.toString().trim() ?? '';
      if (value.isNotEmpty && !result.contains(value)) {
        result.add(value);
      }
    }
  }
  return result;
}

int caseInsensitiveSettingsSort(String a, String b) =>
    a.toLowerCase().compareTo(b.toLowerCase());

bool isGoogleVertexExpressProvider({
  required String providerId,
  Map<String, dynamic>? customConfig,
}) {
  final normalized = ProviderAdapterFactory.resolveProvider(
    providerId,
    customConfig: customConfig,
  );
  return normalized == 'gemini' && isVertexExpressEnabled(customConfig);
}

ModelType _resolveProviderModelType({
  required String providerId,
  required String modelId,
  required Map<String, String> modelTypes,
}) {
  final modelRef = '$providerId:$modelId';
  final stored = modelTypes[modelRef] ?? modelTypes[modelId];
  if (stored != null && stored.trim().isNotEmpty) {
    return ModelType.fromValue(stored.trim());
  }
  return ModelType.inferFromModelId(modelId);
}

List<String> deriveProviderCapabilities({
  required String providerId,
  required List<String> models,
  required Map<String, String> modelTypes,
  List<String>? fallbackCapabilities,
}) {
  final derived = <String>[];
  for (final model in models) {
    final resolved = _resolveProviderModelType(
      providerId: providerId,
      modelId: model,
      modelTypes: modelTypes,
    );
    if (!derived.contains(resolved.value)) {
      derived.add(resolved.value);
    }
  }
  if (derived.isNotEmpty) return derived;

  final fallback = cleanSettingsStrings(fallbackCapabilities);
  if (providerId == 'aliyun' && !fallback.contains('tts')) {
    fallback.add('tts');
  }
  if (fallback.isNotEmpty) return fallback;
  return <String>[ModelType.chat.value];
}

Map<String, dynamic> normalizeUiModelsStoreData(Map<String, dynamic> raw) {
  int normalizeContextWindowTokens(num? value) {
    final limit = value?.toInt() ?? 272000;
    return limit > 0 ? limit : 272000;
  }

  Map<String, dynamic> normalizeAutoReplySettings(dynamic source) {
    final defaults = _defaultAutoReplySettings();
    if (source is! Map) return Map<String, dynamic>.from(defaults);

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

    return <String, dynamic>{
      'enabled': source['enabled'] == true,
      'guard_mode_enabled': source['guard_mode_enabled'] == true,
      'daily_limit': clampInt(
        source['daily_limit'] as num?,
        1,
        10,
        defaults['daily_limit'] as int,
      ),
      'min_interval_minutes': clampInt(
        source['min_interval_minutes'] as num?,
        15,
        720,
        defaults['min_interval_minutes'] as int,
      ),
      'quiet_hours_enabled': source['quiet_hours_enabled'] != false,
      'quiet_hours_start': normalizeTime(
        source['quiet_hours_start'] as String?,
        defaults['quiet_hours_start'] as String,
      ),
      'quiet_hours_end': normalizeTime(
        source['quiet_hours_end'] as String?,
        defaults['quiet_hours_end'] as String,
      ),
      'allow_exact_alarm': source['allow_exact_alarm'] == true,
      'allow_ai_set_reminders': source['allow_ai_set_reminders'] != false,
      'analyzer_prompt':
          (source['analyzer_prompt'] as String?)?.trim().isNotEmpty == true
          ? (source['analyzer_prompt'] as String).trim()
          : defaults['analyzer_prompt'],
      'analyzer_model':
          (source['analyzer_model'] as String?)?.trim().isNotEmpty == true
          ? (source['analyzer_model'] as String).trim()
          : null,
      'analyzer_provider':
          (source['analyzer_provider'] as String?)?.trim().isNotEmpty == true
          ? (source['analyzer_provider'] as String).trim()
          : null,
    };
  }

  Map<String, dynamic> normalizeEnhancedDialogueSettings(dynamic source) {
    final defaults = _defaultEnhancedDialogueSettings();
    if (source is! Map) return Map<String, dynamic>.from(defaults);

    int clampRounds(num? value) {
      if (value == null) return defaults['recent_rounds'] as int;
      final v = value.toInt();
      if (v < 1) return 1;
      if (v > 20) return 20;
      return v;
    }

    final systemPrompt = (source['system_prompt'] as String?)?.trim();
    final bootstrap = (source['bootstrap_user_message'] as String?)?.trim();

    return <String, dynamic>{
      'enabled': source['enabled'] == true,
      'system_prompt': systemPrompt?.isNotEmpty == true
          ? systemPrompt
          : defaults['system_prompt'],
      'bootstrap_user_message': bootstrap?.isNotEmpty == true
          ? bootstrap
          : defaults['bootstrap_user_message'],
      'recent_rounds': clampRounds(source['recent_rounds'] as num?),
    };
  }

  Map<String, dynamic> normalizeCallFlowSettings(dynamic source) {
    final defaults = _defaultCallFlowSettings();
    if (source is! Map) return Map<String, dynamic>.from(defaults);

    int clampInt(num? value, int min, int max, int fallback) {
      if (value == null) return fallback;
      final v = value.toInt();
      if (v < min) return min;
      if (v > max) return max;
      return v;
    }

    final mode = (source['mode'] as String?)?.trim().toLowerCase();
    final normalizedMode = mode == 'fast' ? 'fast' : 'auto';

    return <String, dynamic>{
      'mode': normalizedMode,
      'model_timeout_seconds': clampInt(
        source['model_timeout_seconds'] as num?,
        10,
        300,
        defaults['model_timeout_seconds'] as int,
      ),
      'tool_timeout_seconds': clampInt(
        source['tool_timeout_seconds'] as num?,
        1,
        120,
        defaults['tool_timeout_seconds'] as int,
      ),
    };
  }

  final data = Map<String, dynamic>.from(raw);
  final providersRaw = data['providers'];
  final modelTypes = (data['model_types'] as Map? ?? const <String, dynamic>{})
      .map((key, value) => MapEntry(key.toString(), value?.toString() ?? ''));
  final normalizedProviders = <Map<String, dynamic>>[];
  final visibleUnion = <String>[];

  if (providersRaw is Iterable) {
    for (final entry in providersRaw) {
      if (entry is! Map) continue;
      final provider = Map<String, dynamic>.from(entry.cast<String, dynamic>());
      final id = (provider['id'] as String? ?? '').trim();
      if (id.isEmpty) continue;

      final displayName = (provider['displayName'] as String?)?.trim();
      final apiKeys = cleanSettingsStrings(provider['apiKeys']);
      var apiBaseUrl =
          (provider['apiBaseUrl'] as String? ?? 'https://api.openai.com/v1')
              .trim();
      final enabled = provider['enabled'] is bool
          ? provider['enabled'] as bool
          : true;
      final models = cleanSettingsStrings(provider['models']);
      final visible = cleanSettingsStrings(provider['visible_models']);
      final hidden = cleanSettingsStrings(provider['hidden_models']);
      final capabilities = cleanSettingsStrings(provider['capabilities']);

      var customConfig = provider['custom_config'] is Map
          ? Map<String, dynamic>.from(
              provider['custom_config'] as Map<dynamic, dynamic>,
            )
          : <String, dynamic>{};
      if (id == 'aliyun' && !capabilities.contains('tts')) {
        capabilities.add('tts');
      }

      final ttsModels = customConfig['tts_models'];
      if (ttsModels is List && visible.isEmpty) {
        for (final model in ttsModels) {
          final m = model?.toString().trim() ?? '';
          if (m.isNotEmpty && !visible.contains(m)) {
            visible.add(m);
            if (!models.contains(m)) {
              models.add(m);
            }
          }
        }
        customConfig = Map<String, dynamic>.from(customConfig);
        customConfig.remove('tts_models');
      }

      final requestFormat = customConfig['requestFormat']
          ?.toString()
          .trim()
          .toLowerCase();
      final isNovelAi =
          isNovelAiProvider(providerId: id, apiBaseUrl: apiBaseUrl) ||
          requestFormat == 'novelai' ||
          requestFormat == 'nai';
      if (isNovelAi) {
        apiBaseUrl = normalizeNovelAiBaseUrl(apiBaseUrl);
        final fixedModels = normalizeNovelAiModels(models);
        models
          ..clear()
          ..addAll(fixedModels);

        final fixedVisible = normalizeNovelAiModelIds(visible);
        visible
          ..clear()
          ..addAll(fixedVisible.where((m) => models.contains(m)));
        final fixedHidden = normalizeNovelAiModelIds(hidden);
        hidden
          ..clear()
          ..addAll(
            fixedHidden.where(
              (m) => models.contains(m) && !visible.contains(m),
            ),
          );

        customConfig['requestFormat'] = 'novelai';
        final currentDefault =
            customConfig['defaultImageModel']?.toString().trim() ?? '';
        final normalizedDefault = normalizeNovelAiModelId(currentDefault);
        if (normalizedDefault.isNotEmpty) {
          customConfig['defaultImageModel'] = normalizedDefault;
        } else if (visible.isNotEmpty) {
          customConfig['defaultImageModel'] = visible.first;
        } else if (models.isNotEmpty) {
          customConfig['defaultImageModel'] = models.first;
        }
      } else {
        models.sort(caseInsensitiveSettingsSort);
      }

      final visibleList = <String>[];
      for (final model in visible) {
        if (!models.contains(model) || visibleList.contains(model)) {
          continue;
        }
        visibleList.add(model);
      }
      if (visibleList.isEmpty && models.isNotEmpty) {
        visibleList.add(models.first);
      }

      final hiddenList = <String>[];
      for (final model in hidden) {
        if (!models.contains(model) ||
            visibleList.contains(model) ||
            hiddenList.contains(model)) {
          continue;
        }
        hiddenList.add(model);
      }
      final normalizedCapabilities = isNovelAi && capabilities.isNotEmpty
          ? capabilities
          : deriveProviderCapabilities(
              providerId: id,
              models: models,
              modelTypes: modelTypes,
              fallbackCapabilities: capabilities,
            );
      final contextMessageLimit = (provider['context_message_limit'] as num?)
          ?.toInt();
      final maxContextTokens = (provider['max_context_tokens'] as num?)
          ?.toInt();

      normalizedProviders.add({
        'id': id,
        'displayName': displayName,
        'apiKeys': apiKeys,
        'apiBaseUrl': apiBaseUrl,
        'enabled': enabled,
        'models': models,
        'visible_models': visibleList,
        'hidden_models': hiddenList,
        'capabilities': normalizedCapabilities,
        'custom_config': customConfig,
        if (provider['disable_tool_calling'] == true)
          'disable_tool_calling': true,
        if (provider['temperature'] != null)
          'temperature': provider['temperature'],
        if (provider['top_p'] != null) 'top_p': provider['top_p'],
        if (contextMessageLimit != null)
          'context_message_limit': contextMessageLimit,
        if (maxContextTokens != null) 'max_context_tokens': maxContextTokens,
      });

      if (enabled) {
        for (final model in visibleList) {
          if (!visibleUnion.contains(model)) {
            visibleUnion.add(model);
          }
        }
      }
    }
  }

  data['providers'] = normalizedProviders;
  data['visible_models'] = visibleUnion..sort(caseInsensitiveSettingsSort);
  data['auto_reply_settings'] = normalizeAutoReplySettings(
    data['auto_reply_settings'],
  );
  data['enhanced_dialogue_settings'] = normalizeEnhancedDialogueSettings(
    data['enhanced_dialogue_settings'],
  );
  data['call_flow_settings'] = normalizeCallFlowSettings(
    data['call_flow_settings'],
  );
  data.remove('history_message_limit'); // 退役的条数设置不转换成 token。
  data['context_window_tokens'] = normalizeContextWindowTokens(
    data['context_window_tokens'] as num?,
  );
  data['stream_segment_delay_seconds'] =
      ((data['stream_segment_delay_seconds'] as num?)?.toDouble() ?? 0.0)
          .clamp(0.0, 5.0)
          .toDouble();
  data['windows_window_controls_side'] = WindowControlButtonSide.fromValue(
    data['windows_window_controls_side']?.toString(),
  ).value;
  return data;
}
