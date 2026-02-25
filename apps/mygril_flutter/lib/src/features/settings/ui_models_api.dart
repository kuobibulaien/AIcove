import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api/providers/provider_adapter_factory.dart';

/// SharedPreferences 键名，统一管理模型与渠道配置。
const _kStoreKey = 'aicove.ui_models.v1';
const _kLegacyStoreKeys = <String>[
  // Historical key used by older app naming.
  'mygril.ui_models.v1',
];

/// 本地 API Key 配置缓存（避免重复读取 assets）
Map<String, String>? _localKeysCache;

/// 加载本地 API Key 配置
/// 从 assets/local_keys.json 读取，格式：{"provider_id": "api_key", ...}
Future<Map<String, String>> _loadLocalKeys() async {
  if (_localKeysCache != null) return _localKeysCache!;

  try {
    final jsonStr = await rootBundle.loadString('assets/local_keys.json');
    final data = jsonDecode(jsonStr) as Map<String, dynamic>;
    _localKeysCache = data.map((k, v) => MapEntry(k, v?.toString() ?? ''));
    return _localKeysCache!;
  } catch (e) {
    // 文件不存在或解析失败，返回空 map
    _localKeysCache = {};
    return _localKeysCache!;
  }
}

/// 数据存储的默认结构（KISS：只保留最小必要字段）。
/// 首次初始化时提供DeepSeek测试配置，删除后不再自动恢复。
/// API Key 从 assets/local_keys.json 读取，不硬编码在代码中。
Map<String, dynamic> _defaultStoreData() => <String, dynamic>{
      'providers': [
        // === 英文供应商 ===
        {
          'id': 'deepseek',
          'displayName': 'DeepSeek（测试）',
          'apiKeys': <String>[], // 从 local_keys.json 加载
          'apiBaseUrl': 'https://api.deepseek.com/v1',
          'enabled': true,
          'models': <String>['deepseek-chat'],
          'visible_models': <String>['deepseek-chat'],
          'hidden_models': <String>[],
          'capabilities': <String>['chat'],
          'model_type': 'chat',
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
          'model_type': 'chat',
        },
        {
          'id': 'minimax',
          'displayName': 'MiniMax',
          'apiKeys': <String>[], // 从 local_keys.json 加载
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
          'visible_models': <String>[
            'speech-2.8-hd',
            'speech-2.8-turbo',
          ],
          'hidden_models': <String>[],
          'capabilities': <String>['tts'],
          'model_type': 'tts',
        },
        {
          'id': 'kimi',
          'displayName': 'Kimi',
          'apiKeys': <String>[], // 从 local_keys.json 加载
          'apiBaseUrl': 'https://api.moonshot.cn/v1',
          'enabled': false,
          'models': <String>[],
          'visible_models': <String>[],
          'hidden_models': <String>[],
          'capabilities': <String>['chat'],
          'model_type': 'chat',
        },
        // === 中文供应商 ===
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
          'model_type': 'tts',
        },
        {
          'id': 'novelai',
          'displayName': 'NovelAI',
          'apiKeys': <String>[],
          'apiBaseUrl': 'https://image.novelai.net',
          'enabled': false,
          'models': <String>[
            'nai-diffusion-4-5-curated',
            'nai-diffusion-4-5-full',
            'nai-diffusion-3',
          ],
          'visible_models': <String>[
            'nai-diffusion-4-5-curated',
          ],
          'hidden_models': <String>[],
          'capabilities': <String>['image'],
          'model_type': 'image',
          'customConfig': <String, dynamic>{
            'requestFormat': 'novelai',
            'defaultImageModel': 'nai-diffusion-4-5-curated',
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
          'model_type': 'chat',
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
          'model_type': 'chat',
        },
      ],
      'visible_models': <String>['deepseek-chat'],
      'default_model': 'deepseek-chat',
      'model_display_names': <String, String>{'deepseek-chat': 'DeepSeek Chat'},
      'backend_api_key': '',
      'image_generation_enabled': false,
      'message_chunking_enabled': false,
      'message_format_config': null, // 默认为 null，由前端使用默认配置
      'text_scale_factor': 1.0, // 全局字体缩放因子（默认 1.0）
      'ui_scale_factor': 1.0, // 全局界面缩放因子（默认 1.0）
      'auto_reply_settings': _defaultAutoReplySettings(),
      'enhanced_dialogue_settings': _defaultEnhancedDialogueSettings(),
      'call_flow_settings': _defaultCallFlowSettings(),
      // 主题与界面设置相关字段（后续可按需扩展）
      'chat_background_color': 'default', // 默认跟随全局背景色
      'is_dark_mode': false,
      'use_system_theme': true,
      'hide_user_avatar': true,
      'user_avatar': null,
      'user_name': null,
      'skip_vision_compat_dialog': false,
    };

Map<String, dynamic> _defaultAutoReplySettings() => <String, dynamic>{
      'enabled': false,
      'daily_limit': 3,
      'min_interval_minutes': 120,
      'quiet_hours_enabled': true,
      'quiet_hours_start': '22:00',
      'quiet_hours_end': '08:00',
      'allow_exact_alarm': false,
    };

Map<String, dynamic> _defaultEnhancedDialogueSettings() => <String, dynamic>{
      'enabled': false,
      'system_prompt':
          '''你是“增强对话助手”。你的任务是基于给定的人设与最近对话，生成一条可以直接回复用户的消息，帮助当前会话回到原始人设。

要求：
1. 只输出可直接发送给用户的一段回复，不解释你的推理过程
2. 保持口吻与原人设一致
3. 如需调用工具（如绘图/语音），可正常调用''',
      'bootstrap_user_message': '请输出本轮最终回复，并使用 <enhance>...</enhance> 包裹最终文本。',
      'recent_rounds': 3,
    };

Map<String, dynamic> _defaultCallFlowSettings() => <String, dynamic>{
      'mode': 'stable',
      'model_timeout_seconds': 120,
      'tool_timeout_seconds': 30,
    };

const _novelAiDefaultModels = <String>[
  'nai-diffusion-4-5-curated',
  'nai-diffusion-4-5-full',
  'nai-diffusion-3',
];

const _novelAiModelAliases = <String, String>{
  // Older local presets used this id, but NovelAI now expects "curated".
  'nai-diffusion-4-5-curated-preview': 'nai-diffusion-4-5-curated',
};

bool _isNovelAiProvider({
  required String providerId,
  required String apiBaseUrl,
}) {
  final id = providerId.toLowerCase().trim();
  if (id == 'novelai' || id == 'nai') {
    return true;
  }
  final base = apiBaseUrl.toLowerCase();
  return base.contains('novelai.net');
}

String _normalizeNovelAiBaseUrl(String apiBaseUrl) {
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

String _normalizeNovelAiModelId(String modelId) {
  final trimmed = modelId.trim();
  if (trimmed.isEmpty) return trimmed;
  return _novelAiModelAliases[trimmed] ?? trimmed;
}

List<String> _normalizeNovelAiModels(Iterable<String> models) {
  final normalized = <String>[];
  for (final model in models) {
    final fixed = _normalizeNovelAiModelId(model);
    if (fixed.isEmpty || normalized.contains(fixed)) continue;
    normalized.add(fixed);
  }
  return normalized;
}

Map<String, dynamic> _normalizeAutoReplySettings(dynamic source) {
  final defaults = _defaultAutoReplySettings();
  if (source is! Map) {
    return Map<String, dynamic>.from(defaults);
  }

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
    'daily_limit': clampInt(
        source['daily_limit'] as num?, 1, 10, defaults['daily_limit'] as int),
    'min_interval_minutes': clampInt(source['min_interval_minutes'] as num?, 15,
        720, defaults['min_interval_minutes'] as int),
    'quiet_hours_enabled': source['quiet_hours_enabled'] != false,
    'quiet_hours_start': normalizeTime(source['quiet_hours_start'] as String?,
        defaults['quiet_hours_start'] as String),
    'quiet_hours_end': normalizeTime(source['quiet_hours_end'] as String?,
        defaults['quiet_hours_end'] as String),
    'allow_exact_alarm': source['allow_exact_alarm'] == true,
  };
}

Map<String, dynamic> _normalizeEnhancedDialogueSettings(dynamic source) {
  final defaults = _defaultEnhancedDialogueSettings();
  if (source is! Map) {
    return Map<String, dynamic>.from(defaults);
  }

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

Map<String, dynamic> _normalizeCallFlowSettings(dynamic source) {
  final defaults = _defaultCallFlowSettings();
  if (source is! Map) {
    return Map<String, dynamic>.from(defaults);
  }

  int clampInt(num? value, int min, int max, int fallback) {
    if (value == null) return fallback;
    final v = value.toInt();
    if (v < min) return min;
    if (v > max) return max;
    return v;
  }

  final mode = (source['mode'] as String?)?.trim();
  final normalizedMode = mode == 'fast' ? 'fast' : 'stable';

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

List<String> _cleanStrings(dynamic source) {
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

int _caseSort(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());

Map<String, dynamic> _normalizeData(Map<String, dynamic> raw) {
  final data = Map<String, dynamic>.from(raw);
  final providersRaw = data['providers'];
  final normalizedProviders = <Map<String, dynamic>>[];
  final visibleUnion = <String>[];

  if (providersRaw is Iterable) {
    for (final entry in providersRaw) {
      if (entry is! Map) continue;
      final provider = Map<String, dynamic>.from(entry.cast<String, dynamic>());
      final id = (provider['id'] as String? ?? '').trim();
      if (id.isEmpty) continue;
      final displayName = (provider['displayName'] as String?)?.trim();
      final apiKeys = _cleanStrings(provider['apiKeys']);
      var apiBaseUrl =
          (provider['apiBaseUrl'] as String? ?? 'https://api.openai.com/v1')
              .trim();
      final enabled =
          provider['enabled'] is bool ? provider['enabled'] as bool : true;
      final models = _cleanStrings(provider['models'])..sort(_caseSort);
      final visible = _cleanStrings(provider['visible_models']);
      final hidden = _cleanStrings(provider['hidden_models']);
      final capabilities = _cleanStrings(provider['capabilities']);
      if (capabilities.isEmpty) {
        capabilities.add('chat');
      }

      // 迁移：给阿里云渠道自动补上 tts capability
      var customConfig = provider['custom_config'] is Map
          ? Map<String, dynamic>.from(
              provider['custom_config'] as Map<dynamic, dynamic>)
          : <String, dynamic>{};
      if (id == 'aliyun' && !capabilities.contains('tts')) {
        capabilities.add('tts');
      }

      // 迁移：把旧的 tts_models 迁移到 visible_models
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
        // 清理旧的 tts_models
        customConfig = Map<String, dynamic>.from(customConfig);
        customConfig.remove('tts_models');
      }

      final requestFormat =
          customConfig['requestFormat']?.toString().trim().toLowerCase();
      final isNovelAi =
          _isNovelAiProvider(providerId: id, apiBaseUrl: apiBaseUrl) ||
              requestFormat == 'novelai' ||
              requestFormat == 'nai';
      if (isNovelAi) {
        apiBaseUrl = _normalizeNovelAiBaseUrl(apiBaseUrl);
        final fixedModels = _normalizeNovelAiModels(models)..sort(_caseSort);
        models
          ..clear()
          ..addAll(fixedModels);
        final fixedVisible = _normalizeNovelAiModels(visible);
        visible
          ..clear()
          ..addAll(fixedVisible.where((m) => models.contains(m)));
        final fixedHidden = _normalizeNovelAiModels(hidden);
        hidden
          ..clear()
          ..addAll(
            fixedHidden
                .where((m) => models.contains(m) && !visible.contains(m)),
          );

        customConfig['requestFormat'] = 'novelai';
        final currentDefault =
            customConfig['defaultImageModel']?.toString().trim() ?? '';
        final normalizedDefault = _normalizeNovelAiModelId(currentDefault);
        if (normalizedDefault.isNotEmpty) {
          customConfig['defaultImageModel'] = normalizedDefault;
        } else if (visible.isNotEmpty) {
          customConfig['defaultImageModel'] = visible.first;
        } else if (models.isNotEmpty) {
          customConfig['defaultImageModel'] = models.first;
        }
      }

      final visibleSet = <String>{};
      final hiddenSet = <String>{};

      for (final model in models) {
        if (visible.contains(model)) {
          visibleSet.add(model);
        }
      }
      if (visibleSet.isEmpty && models.isNotEmpty) {
        visibleSet.add(models.first);
      }
      for (final model in hidden) {
        if (!visibleSet.contains(model) && models.contains(model)) {
          hiddenSet.add(model);
        }
      }

      final visibleList = visibleSet.toList()..sort(_caseSort);
      final hiddenList = hiddenSet.toList()..sort(_caseSort);

      final modelType = (provider['model_type'] as String?)?.trim() ?? 'chat';

      normalizedProviders.add({
        'id': id,
        'displayName': displayName,
        'apiKeys': apiKeys,
        'apiBaseUrl': apiBaseUrl,
        'enabled': enabled,
        'models': models,
        'visible_models': visibleList,
        'hidden_models': hiddenList,
        'capabilities': capabilities,
        'custom_config': customConfig,
        'model_type': modelType,
        // 保留模型参数字段
        if (provider['disable_tool_calling'] == true)
          'disable_tool_calling': true,
        if (provider['temperature'] != null)
          'temperature': provider['temperature'],
        if (provider['top_p'] != null) 'top_p': provider['top_p'],
        if (provider['context_message_limit'] != null)
          'context_message_limit': provider['context_message_limit'],
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
  data['visible_models'] = visibleUnion..sort(_caseSort);
  data['auto_reply_settings'] =
      _normalizeAutoReplySettings(data['auto_reply_settings']);
  data['enhanced_dialogue_settings'] =
      _normalizeEnhancedDialogueSettings(data['enhanced_dialogue_settings']);
  data['call_flow_settings'] =
      _normalizeCallFlowSettings(data['call_flow_settings']);
  return data;
}

class UiModelsApi {
  const UiModelsApi();

  Future<Map<String, dynamic>> fetchAll() async {
    final prefs = await SharedPreferences.getInstance();
    return _loadStore(prefs);
  }

  Future<Map<String, dynamic>> updatePartial(
    Map<String, dynamic> partial, {
    String? bearerToken,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await _loadStore(prefs);
    final next = Map<String, dynamic>.from(current);
    next.addAll(partial);
    return _writeStore(prefs, next);
  }

  Future<List<String>> previewProvider({
    required String providerId,
    required String apiKey,
    required String apiBaseUrl,
  }) async {
    if (_isNovelAiProvider(providerId: providerId, apiBaseUrl: apiBaseUrl)) {
      return _novelAiDefaultModels;
    }

    try {
      final url = '${apiBaseUrl.replaceAll(RegExp(r'/+$'), '')}/models';
      final response = await http.get(
        Uri.parse(url),
        headers: {'Authorization': 'Bearer $apiKey'},
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final models = (data['data'] as List?)
              ?.whereType<Map>()
              .map((e) => (e['id'] as String?)?.trim() ?? '')
              .where((e) => e.isNotEmpty)
              .toList() ??
          <String>[];

      if (models.isEmpty) {
        throw Exception('No models found');
      }

      return models;
    } catch (e) {
      throw Exception('Failed to fetch models: $e');
    }
  }

  /// 测试指定模型是否可用：发送一条极简的 chat completion 请求
  /// 返回模型的回复文本（成功则非空），失败则抛出异常
  Future<String> testModel({
    required String providerId,
    required String apiKey,
    required String apiBaseUrl,
    required String modelId,
  }) async {
    try {
      final adapter = ProviderAdapterFactory.getAdapter(providerId);
      final endpoint = adapter.buildEndpoint(
        apiBaseUrl.replaceAll(RegExp(r'/+$'), ''),
        modelType: 'chat',
      );
      final headers = adapter.buildHeaders(apiKey);
      final body = adapter.buildRequestBody(
        model: modelId,
        messages: [
          {'role': 'user', 'content': 'hi'},
        ],
        customConfig: {'max_tokens': 3},
      );

      final response = await http
          .post(Uri.parse(endpoint), headers: headers, body: jsonEncode(body))
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        final msg = response.body.length > 200
            ? response.body.substring(0, 200)
            : response.body;
        throw Exception('HTTP ${response.statusCode}: $msg');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final result = adapter.parseResponse(data);
      return result.text.isNotEmpty ? result.text : '(模型响应成功，无文本内容)';
    } catch (e) {
      throw Exception('模型测试失败: $e');
    }
  }

  Future<Map<String, dynamic>> importProvider({
    required String providerId,
    String? model,
    required String apiKey,
    required String apiBaseUrl,
    String? displayName,
    List<String>? visibleModels,
    List<String>? hiddenModels,
    List<String>? allModels,
    List<String>? capabilities,
    Map<String, dynamic>? customConfig,
    String? modelType,
  }) async {
    if (providerId != 'openai_full_compat' && apiKey.trim().isEmpty) {
      throw ArgumentError('provider_id 和 api_key 不能为空');
    }

    final prefs = await SharedPreferences.getInstance();
    final current = await _loadStore(prefs);
    final providers = (current['providers'] as List)
        .cast<Map<String, dynamic>>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final requestFormat =
        customConfig?['requestFormat']?.toString().trim().toLowerCase();
    final isNovelAi =
        _isNovelAiProvider(providerId: providerId, apiBaseUrl: apiBaseUrl) ||
            requestFormat == 'novelai' ||
            requestFormat == 'nai';

    List<String> models;
    if (allModels != null) {
      models = _cleanStrings(allModels);
    } else {
      try {
        models = await previewProvider(
          providerId: providerId,
          apiKey: apiKey,
          apiBaseUrl: apiBaseUrl,
        );
      } catch (e) {
        if (isNovelAi) {
          models = _novelAiDefaultModels;
        } else {
          rethrow;
        }
      }
    }

    if (model != null &&
        model.trim().isNotEmpty &&
        !models.contains(model.trim())) {
      models.insert(0, model.trim());
    }
    if (isNovelAi) {
      models = _normalizeNovelAiModels(models);
    }

    var visible = _cleanStrings(
      visibleModels ?? (model != null ? [model] : models.take(3)),
    );
    var hidden = _cleanStrings(hiddenModels);
    if (isNovelAi) {
      visible = _normalizeNovelAiModels(visible);
      hidden = _normalizeNovelAiModels(hidden);
    }
    final caps = _cleanStrings(capabilities);
    if (caps.isEmpty) caps.add('chat');
    final normalizedConfig = Map<String, dynamic>.from(customConfig ?? {});
    if (isNovelAi) {
      normalizedConfig['requestFormat'] = 'novelai';
      if ((normalizedConfig['defaultImageModel']?.toString().trim() ?? '')
          .isEmpty) {
        if (visible.isNotEmpty) {
          normalizedConfig['defaultImageModel'] = visible.first;
        } else if (models.isNotEmpty) {
          normalizedConfig['defaultImageModel'] = models.first;
        }
      } else {
        normalizedConfig['defaultImageModel'] = _normalizeNovelAiModelId(
          normalizedConfig['defaultImageModel']?.toString() ?? '',
        );
      }
    }
    final normalizedApiBaseUrl = isNovelAi
        ? _normalizeNovelAiBaseUrl(apiBaseUrl)
        : (apiBaseUrl.trim().isEmpty
            ? 'https://api.openai.com/v1'
            : apiBaseUrl.trim());

    final entry = <String, dynamic>{
      'id': providerId,
      'displayName':
          displayName?.trim().isEmpty == true ? null : displayName?.trim(),
      'apiKeys': apiKey.trim().isEmpty ? <String>[] : <String>[apiKey.trim()],
      'apiBaseUrl': normalizedApiBaseUrl,
      'enabled': true,
      'models': models,
      'visible_models': visible,
      'hidden_models': hidden.where((m) => !visible.contains(m)).toList(),
      'capabilities': caps,
      'custom_config': normalizedConfig,
      'model_type': modelType?.trim().isEmpty == true
          ? 'chat'
          : (modelType?.trim() ?? 'chat'),
    };

    providers.removeWhere((p) => p['id'] == providerId);
    providers.add(entry);
    current['providers'] = providers;
    if (visible.isNotEmpty) {
      current['default_model'] = visible.first;
    } else if (models.isNotEmpty) {
      current['default_model'] = models.first;
    }

    return _writeStore(prefs, current);
  }

  Future<Map<String, dynamic>> updateProvider({
    required String providerId,
    String? displayName,
    String? apiBaseUrl,
    List<String>? apiKeys,
    bool? enabled,
    List<String>? capabilities,
    Map<String, dynamic>? customConfig,
    String? modelType,
    List<String>? allModels,
    List<String>? visibleModels,
    List<String>? hiddenModels,
    bool? disableToolCalling,
    // 模型参数
    double? temperature,
    bool clearTemperature = false,
    double? topP,
    bool clearTopP = false,
    int? contextMessageLimit,
    bool clearContextMessageLimit = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await _loadStore(prefs);
    final providers = (current['providers'] as List)
        .cast<Map<String, dynamic>>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final index = providers.indexWhere((p) => p['id'] == providerId);
    if (index < 0) {
      throw ArgumentError('Provider [$providerId] 不存在');
    }
    final provider = providers[index];
    if (displayName != null) {
      provider['displayName'] =
          displayName.trim().isEmpty ? null : displayName.trim();
    }
    if (apiBaseUrl != null && apiBaseUrl.trim().isNotEmpty) {
      final nextBase = apiBaseUrl.trim();
      final mergedRequestFormat = (customConfig?['requestFormat'] ??
              (provider['custom_config'] is Map
                  ? (provider['custom_config'] as Map)['requestFormat']
                  : null))
          ?.toString()
          .trim()
          .toLowerCase();
      final isNovelAi =
          _isNovelAiProvider(providerId: providerId, apiBaseUrl: nextBase) ||
              mergedRequestFormat == 'novelai' ||
              mergedRequestFormat == 'nai';
      provider['apiBaseUrl'] =
          isNovelAi ? _normalizeNovelAiBaseUrl(nextBase) : nextBase;
    }
    if (apiKeys != null) {
      provider['apiKeys'] = _cleanStrings(apiKeys);
    }
    if (enabled != null) {
      provider['enabled'] = enabled;
    }
    if (capabilities != null) {
      provider['capabilities'] = _cleanStrings(capabilities);
    }
    if (customConfig != null) {
      provider['custom_config'] = customConfig;
    }
    if (modelType != null && modelType.trim().isNotEmpty) {
      provider['model_type'] = modelType.trim();
    }
    // 模型列表更新
    if (allModels != null) {
      provider['models'] = _cleanStrings(allModels)..sort(_caseSort);
    }
    if (visibleModels != null) {
      provider['visible_models'] = _cleanStrings(visibleModels);
    }
    if (hiddenModels != null) {
      provider['hidden_models'] = _cleanStrings(hiddenModels);
    }
    if (disableToolCalling != null) {
      provider['disable_tool_calling'] = disableToolCalling;
    }
    // 模型参数更新
    if (clearTemperature) {
      provider.remove('temperature');
    } else if (temperature != null) {
      provider['temperature'] = temperature;
    }
    if (clearTopP) {
      provider.remove('top_p');
    } else if (topP != null) {
      provider['top_p'] = topP;
    }
    if (clearContextMessageLimit) {
      provider.remove('context_message_limit');
    } else if (contextMessageLimit != null) {
      provider['context_message_limit'] = contextMessageLimit;
    }
    providers[index] = provider;
    current['providers'] = providers;
    return _writeStore(prefs, current);
  }

  Future<Map<String, dynamic>> deleteProvider(String providerId) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await _loadStore(prefs);
    final providers = (current['providers'] as List)
        .cast<Map<String, dynamic>>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    providers.removeWhere((p) => p['id'] == providerId);
    current['providers'] = providers;
    return _writeStore(prefs, current);
  }

  Future<Map<String, dynamic>> reorderProviders(
      List<String> providerIds) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await _loadStore(prefs);
    final providers = (current['providers'] as List)
        .cast<Map<String, dynamic>>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();

    // 按照新的顺序重新排列
    final reordered = <Map<String, dynamic>>[];
    for (final id in providerIds) {
      final provider = providers.firstWhere(
        (p) => p['id'] == id,
        orElse: () => <String, dynamic>{},
      );
      if (provider.isNotEmpty) {
        reordered.add(provider);
      }
    }

    current['providers'] = reordered;
    return _writeStore(prefs, current);
  }

  Future<Map<String, dynamic>> reorderProviderModels({
    required String providerId,
    required List<String> modelIds,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await _loadStore(prefs);
    final providers = (current['providers'] as List)
        .cast<Map<String, dynamic>>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();

    final index = providers.indexWhere((p) => p['id'] == providerId);
    if (index < 0) return current;

    final provider = providers[index];

    // 更新 visible_models 的顺序
    provider['visible_models'] = modelIds;
    providers[index] = provider;
    current['providers'] = providers;

    return _writeStore(prefs, current);
  }

  Future<Map<String, dynamic>> _loadStore(SharedPreferences prefs) async {
    final raw = prefs.getString(_kStoreKey);
    if (raw == null || raw.isEmpty) {
      final migrated = await _tryMigrateLegacyStore(prefs);
      if (migrated != null) return migrated;

      final defaults = await _applyLocalKeys(_defaultStoreData());
      await prefs.setString(_kStoreKey, jsonEncode(defaults));
      return _normalizeData(defaults);
    }
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      // 每次加载时检查并补充本地 key（用户清空数据后自动恢复）
      final withKeys = await _applyLocalKeys(data);
      return _normalizeData(withKeys);
    } catch (e) {
      final migrated = await _tryMigrateLegacyStore(prefs);
      if (migrated != null) return migrated;

      final defaults = await _applyLocalKeys(_defaultStoreData());
      await prefs.setString(_kStoreKey, jsonEncode(defaults));
      return _normalizeData(defaults);
    }
  }

  Future<Map<String, dynamic>?> _tryMigrateLegacyStore(
      SharedPreferences prefs) async {
    for (final legacyKey in _kLegacyStoreKeys) {
      final raw = prefs.getString(legacyKey);
      if (raw == null || raw.isEmpty) continue;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic>) continue;
        final withKeys =
            await _applyLocalKeys(Map<String, dynamic>.from(decoded));
        final normalized = _normalizeData(withKeys);
        await prefs.setString(_kStoreKey, jsonEncode(normalized));
        return normalized;
      } catch (_) {
        // Ignore invalid legacy payload.
      }
    }
    return null;
  }

  /// 将本地 key 注入到 provider 配置中
  /// 只有当 provider 的 apiKeys 为空时才注入
  /// 同时为阿里云等渠道补充默认模型列表
  Future<Map<String, dynamic>> _applyLocalKeys(
      Map<String, dynamic> data) async {
    final localKeys = await _loadLocalKeys();
    final providers = data['providers'];
    if (providers is! List) return data;

    // 获取默认配置，用于补充模型列表
    final defaults = _defaultStoreData();
    final defaultProviders =
        (defaults['providers'] as List).cast<Map<String, dynamic>>();

    for (final provider in providers) {
      if (provider is! Map) continue;
      final id = provider['id'] as String?;
      if (id == null) continue;

      // 注入本地 key
      final existingKeys = provider['apiKeys'];
      final hasKey = existingKeys is List &&
          existingKeys.isNotEmpty &&
          existingKeys.any((k) => k?.toString().trim().isNotEmpty == true);

      if (!hasKey && localKeys.containsKey(id)) {
        final localKey = localKeys[id]?.trim() ?? '';
        if (localKey.isNotEmpty) {
          provider['apiKeys'] = <String>[localKey];
        }
      }

      // 补充模型列表（当模型列表为空时，从默认配置补充）
      final models = provider['models'];
      final hasModels = models is List && models.isNotEmpty;
      if (!hasModels) {
        final defaultProvider = defaultProviders.firstWhere(
          (p) => p['id'] == id,
          orElse: () => <String, dynamic>{},
        );
        if (defaultProvider.isNotEmpty) {
          final defaultModels = defaultProvider['models'];
          if (defaultModels is List && defaultModels.isNotEmpty) {
            provider['models'] = List<String>.from(defaultModels);
            provider['visible_models'] = List<String>.from(
                defaultProvider['visible_models'] ?? defaultModels);
          }
        }
      }
    }

    return data;
  }

  Future<Map<String, dynamic>> _writeStore(
    SharedPreferences prefs,
    Map<String, dynamic> data,
  ) async {
    final normalized = _normalizeData(data);
    await prefs.setString(_kStoreKey, jsonEncode(normalized));
    return normalized;
  }
}
