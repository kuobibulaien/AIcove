import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences 键名，统一管理模型与渠道配置。
const _kStoreKey = 'mygril.ui_models.v1';

/// 数据存储的默认结构（KISS：只保留最小必要字段）。
/// 首次初始化时提供DeepSeek测试配置，删除后不再自动恢复。
Map<String, dynamic> _defaultStoreData() => <String, dynamic>{
      'providers': [
        {
          'id': 'deepseek',
          'displayName': 'DeepSeek（测试）',
          'apiKeys': <String>['sk-91b7553cdfd84799b7552b34d1665153'],
          'apiBaseUrl': 'https://api.deepseek.com/v1',
          'enabled': true,
          'models': <String>['deepseek-chat'],
          'visible_models': <String>['deepseek-chat'],
          'hidden_models': <String>[],
          'capabilities': <String>['chat'],
          'model_type': 'chat',
        },
      ],
      'visible_models': <String>['deepseek-chat'],
      'default_model': 'deepseek-chat',
      'model_display_names': <String, String>{'deepseek-chat': 'DeepSeek Chat'},
      'backend_api_key': '',
      'message_chunking_enabled': false,
      'message_format_config': null, // 默认为 null，由前端使用默认配置
      'message_font_size': 13.0, // 默认中等大小
      'auto_reply_settings': _defaultAutoReplySettings(),
      // 主题与界面设置相关字段（后续可按需扩展）
      'chat_background_color': 'white', // 对应 ChatBackgroundColor.white
      'is_dark_mode': false,
      'use_system_theme': true,
      'user_avatar': null,
      'user_name': null,
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

Map<String, dynamic> _normalizeAutoReplySettings(dynamic source) {
  final defaults = _defaultAutoReplySettings();
  if (source is! Map) {
    return Map<String, dynamic>.from(defaults);
  }

  String _normalizeTime(String? value, String fallback) {
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

  int _clampInt(num? value, int min, int max, int fallback) {
    if (value == null) return fallback;
    final v = value.toInt();
    if (v < min) return min;
    if (v > max) return max;
    return v;
  }

  return <String, dynamic>{
    'enabled': source['enabled'] == true,
    'daily_limit': _clampInt(source['daily_limit'] as num?, 1, 10, defaults['daily_limit'] as int),
    'min_interval_minutes':
        _clampInt(source['min_interval_minutes'] as num?, 15, 720, defaults['min_interval_minutes'] as int),
    'quiet_hours_enabled': source['quiet_hours_enabled'] != false,
    'quiet_hours_start': _normalizeTime(source['quiet_hours_start'] as String?, defaults['quiet_hours_start'] as String),
    'quiet_hours_end': _normalizeTime(source['quiet_hours_end'] as String?, defaults['quiet_hours_end'] as String),
    'allow_exact_alarm': source['allow_exact_alarm'] == true,
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
      final apiBaseUrl =
          (provider['apiBaseUrl'] as String? ?? 'https://api.openai.com/v1').trim();
      final enabled = provider['enabled'] is bool ? provider['enabled'] as bool : true;
      final models = _cleanStrings(provider['models'])..sort(_caseSort);
      final visible = _cleanStrings(provider['visible_models']);
      final hidden = _cleanStrings(provider['hidden_models']);
      final capabilities = _cleanStrings(provider['capabilities']);
      if (capabilities.isEmpty) {
        capabilities.add('chat');
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
        'custom_config': provider['custom_config'] ?? {},
        'model_type': modelType,
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
  data['auto_reply_settings'] = _normalizeAutoReplySettings(data['auto_reply_settings']);
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
          .toList() ?? <String>[];

      if (models.isEmpty) {
        throw Exception('No models found');
      }

      return models;
    } catch (e) {
      throw Exception('Failed to fetch models: $e');
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

    final models =
        allModels != null ? _cleanStrings(allModels) : await previewProvider(
              providerId: providerId,
              apiKey: apiKey,
              apiBaseUrl: apiBaseUrl,
            );

    if (model != null && model.trim().isNotEmpty && !models.contains(model.trim())) {
      models.insert(0, model.trim());
    }

    final visible = _cleanStrings(
      visibleModels ?? (model != null ? [model] : models.take(3)),
    );
    final hidden = _cleanStrings(hiddenModels);
    final caps = _cleanStrings(capabilities);
    if (caps.isEmpty) caps.add('chat');

    final entry = <String, dynamic>{
      'id': providerId,
      'displayName': displayName?.trim().isEmpty == true ? null : displayName?.trim(),
      'apiKeys': apiKey.trim().isEmpty ? <String>[] : <String>[apiKey.trim()],
      'apiBaseUrl': apiBaseUrl.trim().isEmpty ? 'https://api.openai.com/v1' : apiBaseUrl.trim(),
      'enabled': true,
      'models': models,
      'visible_models': visible,
      'hidden_models': hidden.where((m) => !visible.contains(m)).toList(),
      'capabilities': caps,
      'custom_config': customConfig ?? {},
      'model_type': modelType?.trim().isEmpty == true ? 'chat' : (modelType?.trim() ?? 'chat'),
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
      provider['displayName'] = displayName.trim().isEmpty ? null : displayName.trim();
    }
    if (apiBaseUrl != null && apiBaseUrl.trim().isNotEmpty) {
      provider['apiBaseUrl'] = apiBaseUrl.trim();
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

  Future<Map<String, dynamic>> _loadStore(SharedPreferences prefs) async {
    final raw = prefs.getString(_kStoreKey);
    if (raw == null || raw.isEmpty) {
      final defaults = _defaultStoreData();
      await prefs.setString(_kStoreKey, jsonEncode(defaults));
      return _normalizeData(defaults);
    }
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      return _normalizeData(data);
    } catch (e) {
      final defaults = _defaultStoreData();
      await prefs.setString(_kStoreKey, jsonEncode(defaults));
      return _normalizeData(defaults);
    }
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
