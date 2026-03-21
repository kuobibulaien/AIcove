import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/ui_models_store_support.dart';

/// 设置模块本地存储数据源。
/// 只负责 SharedPreferences 持久化、默认值兜底和本地 key 注入。
class UiModelsStoreLocalDataSource {
  const UiModelsStoreLocalDataSource();

  Future<Map<String, dynamic>> fetchAll() async {
    final prefs = await SharedPreferences.getInstance();
    return _loadStore(prefs);
  }

  Future<Map<String, dynamic>> updatePartial(
    Map<String, dynamic> partial,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await _loadStore(prefs);
    final next = Map<String, dynamic>.from(current);
    next.addAll(partial);
    return _writeStore(prefs, next);
  }

  Future<Map<String, dynamic>> importProvider({
    required String providerId,
    String? model,
    required String apiKey,
    required String apiBaseUrl,
    String? displayName,
    List<String>? visibleModels,
    List<String>? hiddenModels,
    List<String>? capabilities,
    Map<String, dynamic>? customConfig,
    required List<String> models,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await _loadStore(prefs);
    final modelTypes = (current['model_types'] as Map? ??
            const <String, dynamic>{})
        .map((key, value) => MapEntry(key.toString(), value?.toString() ?? ''));
    final providers = _copyProviders(current);
    final requestFormat =
        customConfig?['requestFormat']?.toString().trim().toLowerCase();
    final isNovelAi =
        isNovelAiProvider(providerId: providerId, apiBaseUrl: apiBaseUrl) ||
            requestFormat == 'novelai' ||
            requestFormat == 'nai';

    var visible = cleanSettingsStrings(
      visibleModels ?? (model != null ? [model] : models.take(3)),
    );
    var hidden = cleanSettingsStrings(hiddenModels);
    if (isNovelAi) {
      visible = normalizeNovelAiModels(visible);
      hidden = normalizeNovelAiModels(hidden);
    }
    visible = visible.where((m) => models.contains(m)).toList();
    hidden = hidden
        .where((m) => models.contains(m) && !visible.contains(m))
        .toList();

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
        normalizedConfig['defaultImageModel'] = normalizeNovelAiModelId(
          normalizedConfig['defaultImageModel']?.toString() ?? '',
        );
      }
    }

    final normalizedApiBaseUrl = isNovelAi
        ? normalizeNovelAiBaseUrl(apiBaseUrl)
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
      'capabilities': deriveProviderCapabilities(
        providerId: providerId,
        models: models,
        modelTypes: modelTypes,
        fallbackCapabilities: capabilities,
      ),
      'custom_config': normalizedConfig,
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
    List<String>? allModels,
    List<String>? visibleModels,
    List<String>? hiddenModels,
    bool? disableToolCalling,
    double? temperature,
    bool clearTemperature = false,
    double? topP,
    bool clearTopP = false,
    int? contextMessageLimit,
    bool clearContextMessageLimit = false,
    int? maxContextTokens,
    bool clearMaxContextTokens = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await _loadStore(prefs);
    final providers = _copyProviders(current);
    final index = providers.indexWhere((p) => p['id'] == providerId);
    if (index < 0) {
      throw ArgumentError('Provider [$providerId] 不存在');
    }

    final provider = providers[index];
    final currentModelTypes = (current['model_types'] as Map? ??
            const <String, dynamic>{})
        .map((key, value) => MapEntry(key.toString(), value?.toString() ?? ''));

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
          isNovelAiProvider(providerId: providerId, apiBaseUrl: nextBase) ||
              mergedRequestFormat == 'novelai' ||
              mergedRequestFormat == 'nai';
      provider['apiBaseUrl'] =
          isNovelAi ? normalizeNovelAiBaseUrl(nextBase) : nextBase;
    }
    if (apiKeys != null) {
      provider['apiKeys'] = cleanSettingsStrings(apiKeys);
    }
    if (enabled != null) {
      provider['enabled'] = enabled;
    }
    if (customConfig != null) {
      provider['custom_config'] = customConfig;
    }
    if (allModels != null) {
      final cleaned = cleanSettingsStrings(allModels)
        ..sort(caseInsensitiveSettingsSort);
      provider['models'] = cleaned;
    }
    if (visibleModels != null) {
      final models = cleanSettingsStrings(provider['models']);
      provider['visible_models'] = cleanSettingsStrings(visibleModels)
          .where((m) => models.contains(m))
          .toList();
    }
    if (hiddenModels != null) {
      final models = cleanSettingsStrings(provider['models']);
      final visible = cleanSettingsStrings(provider['visible_models']);
      provider['hidden_models'] = cleanSettingsStrings(hiddenModels)
          .where((m) => models.contains(m) && !visible.contains(m))
          .toList();
    }
    if (disableToolCalling != null) {
      provider['disable_tool_calling'] = disableToolCalling;
    }
    provider['capabilities'] = deriveProviderCapabilities(
      providerId: providerId,
      models: cleanSettingsStrings(provider['models']),
      modelTypes: currentModelTypes,
      fallbackCapabilities:
          capabilities ?? cleanSettingsStrings(provider['capabilities']),
    );

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
    if (clearMaxContextTokens) {
      provider.remove('max_context_tokens');
    } else if (maxContextTokens != null) {
      provider['max_context_tokens'] = maxContextTokens;
    }

    providers[index] = provider;
    current['providers'] = providers;
    return _writeStore(prefs, current);
  }

  Future<Map<String, dynamic>> deleteProvider(String providerId) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await _loadStore(prefs);
    final providers = _copyProviders(current);
    providers.removeWhere((p) => p['id'] == providerId);
    current['providers'] = providers;
    return _writeStore(prefs, current);
  }

  Future<Map<String, dynamic>> reorderProviders(
    List<String> providerIds,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await _loadStore(prefs);
    final providers = _copyProviders(current);

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
    final providers = _copyProviders(current);

    final index = providers.indexWhere((p) => p['id'] == providerId);
    if (index < 0) return current;

    final provider = providers[index];
    provider['visible_models'] = modelIds;
    providers[index] = provider;
    current['providers'] = providers;
    return _writeStore(prefs, current);
  }

  List<Map<String, dynamic>> _copyProviders(Map<String, dynamic> current) {
    return (current['providers'] as List? ?? const <dynamic>[])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e.cast<String, dynamic>()))
        .toList();
  }

  Future<Map<String, dynamic>> _loadStore(SharedPreferences prefs) async {
    final raw = prefs.getString(kUiModelsStoreKey);
    if (raw == null || raw.isEmpty) {
      final migrated = await _tryMigrateLegacyStore(prefs);
      if (migrated != null) return migrated;

      final defaults = await _applyLocalKeys(buildDefaultUiModelsStoreData());
      await prefs.setString(kUiModelsStoreKey, jsonEncode(defaults));
      return normalizeUiModelsStoreData(defaults);
    }

    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final withKeys = await _applyLocalKeys(data);
      final normalized = normalizeUiModelsStoreData(withKeys);
      final normalizedJson = jsonEncode(normalized);
      if (normalizedJson != raw) {
        await prefs.setString(kUiModelsStoreKey, normalizedJson);
      }
      return normalized;
    } catch (_) {
      final migrated = await _tryMigrateLegacyStore(prefs);
      if (migrated != null) return migrated;

      final defaults = await _applyLocalKeys(buildDefaultUiModelsStoreData());
      await prefs.setString(kUiModelsStoreKey, jsonEncode(defaults));
      return normalizeUiModelsStoreData(defaults);
    }
  }

  Future<Map<String, dynamic>?> _tryMigrateLegacyStore(
    SharedPreferences prefs,
  ) async {
    for (final legacyKey in kUiModelsLegacyStoreKeys) {
      final raw = prefs.getString(legacyKey);
      if (raw == null || raw.isEmpty) continue;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic>) continue;
        final withKeys =
            await _applyLocalKeys(Map<String, dynamic>.from(decoded));
        final normalized = normalizeUiModelsStoreData(withKeys);
        await prefs.setString(kUiModelsStoreKey, jsonEncode(normalized));
        return normalized;
      } catch (_) {
        // Ignore invalid legacy payload.
      }
    }
    return null;
  }

  Future<Map<String, dynamic>> _applyLocalKeys(
    Map<String, dynamic> data,
  ) async {
    final localKeys = await _loadLocalKeys();
    final providers = data['providers'];
    if (providers is! List) return data;

    final defaults = buildDefaultUiModelsStoreData();
    final defaultProviders =
        (defaults['providers'] as List? ?? const <dynamic>[])
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList(growable: false);

    for (final provider in providers) {
      if (provider is! Map) continue;
      final id = provider['id'] as String?;
      if (id == null) continue;

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
              defaultProvider['visible_models'] ?? defaultModels,
            );
          }
        }
      }
    }

    return data;
  }

  Future<Map<String, String>> _loadLocalKeys() async {
    if (_localKeysCache != null) return _localKeysCache!;

    try {
      final jsonStr = await rootBundle.loadString('assets/local_keys.json');
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      _localKeysCache = data.map((k, v) => MapEntry(k, v?.toString() ?? ''));
      return _localKeysCache!;
    } catch (_) {
      _localKeysCache = <String, String>{};
      return _localKeysCache!;
    }
  }

  Future<Map<String, dynamic>> _writeStore(
    SharedPreferences prefs,
    Map<String, dynamic> data,
  ) async {
    final normalized = normalizeUiModelsStoreData(data);
    await prefs.setString(kUiModelsStoreKey, jsonEncode(normalized));
    return normalized;
  }
}

Map<String, String>? _localKeysCache;
