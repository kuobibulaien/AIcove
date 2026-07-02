library;

import 'dart:math';

import '../../settings/app_settings.dart';
import '../../settings/direct_mode.dart' as direct;
import '../../settings/mcp_api.dart';

/// Request-level config for one chat model attempt.
class ChatRequestConfig {
  /// Raw model reference key used by AppSettings APIs.
  final String modelRef;

  /// Full model id in `provider:model` format.
  final String modelFullId;

  /// Provider API base URL.
  final String providerApiBase;

  /// Provider API key.
  final String? providerApiKey;

  /// Provider id from the selected model reference.
  final String providerId;

  /// Selected multi-key item id when provider multi-key mode is active.
  final String? providerApiKeyItemId;

  /// Selected multi-key item index in `multi_key_items`.
  final int? providerApiKeyItemIndex;

  /// Multi-key strategy used for the selected key.
  final String? providerApiKeyStrategy;

  /// Tool preference payload sent to backend.
  final Map<String, dynamic> toolPrefs;

  /// Provider custom config passed through to backend.
  final Map<String, dynamic> customConfig;

  /// Model-level temperature override.
  final double? modelTemperature;

  /// Model-level topP override.
  final double? modelTopP;

  /// Model-level context message limit override.
  final int? modelContextMessageLimit;

  const ChatRequestConfig({
    required this.modelRef,
    required this.modelFullId,
    required this.providerApiBase,
    this.providerApiKey,
    required this.providerId,
    this.providerApiKeyItemId,
    this.providerApiKeyItemIndex,
    this.providerApiKeyStrategy,
    required this.toolPrefs,
    this.customConfig = const <String, dynamic>{},
    this.modelTemperature,
    this.modelTopP,
    this.modelContextMessageLimit,
  });
}

class _ProviderApiKeyCandidate {
  const _ProviderApiKeyCandidate({
    required this.key,
    required this.enabled,
    required this.isError,
    this.id,
    this.index,
  });

  final String key;
  final bool enabled;
  final bool isError;
  final String? id;
  final int? index;
}

class _ProviderApiKeySelection {
  const _ProviderApiKeySelection({
    required this.key,
    this.itemId,
    this.itemIndex,
    this.strategy,
  });

  final String? key;
  final String? itemId;
  final int? itemIndex;
  final String? strategy;
}

/// Builds chat request config with MCP cache and direct-mode fallback.
class ChatRequestConfigBuilder {
  static const String _multiKeyEnabledField = 'multi_key_enabled';
  static const String _multiKeyStrategyField = 'multi_key_strategy';
  static const String _multiKeyItemsField = 'multi_key_items';
  static const String _multiKeyRoundRobinIndexField = 'multi_key_rr_index';
  static const String _multiKeyRoundRobin = 'round_robin';
  static const String _multiKeyRandom = 'random';
  static const String _multiKeyExhaust = 'exhaust';
  static final Map<String, int> _roundRobinIndexMap = <String, int>{};

  final McpApi _mcpApi = McpApi();
  McpConfigDto? _cachedMcpConfig;
  DateTime? _cachedMcpFetchedAt;

  _ProviderApiKeySelection _selectProviderApiKey(ProviderAuth providerAuth) {
    final fallback = providerAuth.apiKeys.isNotEmpty
        ? providerAuth.apiKeys.first.trim()
        : null;

    final customConfig = providerAuth.customConfig;
    if (customConfig[_multiKeyEnabledField] != true) {
      return _ProviderApiKeySelection(
        key: fallback?.isEmpty == true ? null : fallback,
      );
    }

    final items = <_ProviderApiKeyCandidate>[];
    final rawItems = customConfig[_multiKeyItemsField];
    if (rawItems is List) {
      for (var i = 0; i < rawItems.length; i++) {
        final item = rawItems[i];
        if (item is! Map) continue;
        final mapped = Map<String, dynamic>.from(item);
        final key = mapped['key']?.toString().trim() ?? '';
        if (key.isEmpty) continue;
        final id = mapped['id']?.toString().trim();
        final enabled = mapped['enabled'] != false;
        final status =
            mapped['status']?.toString().trim().toLowerCase() ?? 'normal';
        items.add(_ProviderApiKeyCandidate(
          key: key,
          enabled: enabled,
          isError: status == 'error',
          id: id?.isEmpty == true ? null : id,
          index: i,
        ));
      }
    }

    if (items.isEmpty) {
      for (var i = 0; i < providerAuth.apiKeys.length; i++) {
        final raw = providerAuth.apiKeys[i];
        final key = raw.trim();
        if (key.isEmpty) continue;
        items.add(_ProviderApiKeyCandidate(
          key: key,
          enabled: true,
          isError: false,
          index: i,
        ));
      }
    }
    if (items.isEmpty) {
      return _ProviderApiKeySelection(
        key: fallback?.isEmpty == true ? null : fallback,
      );
    }

    var available = items
        .where((item) => item.enabled && !item.isError && item.key.isNotEmpty)
        .toList();
    available = available.isEmpty
        ? items.where((item) => item.enabled && item.key.isNotEmpty).toList()
        : available;
    if (available.isEmpty) {
      return _ProviderApiKeySelection(
        key: fallback?.isEmpty == true ? null : fallback,
      );
    }

    final strategy =
        customConfig[_multiKeyStrategyField]?.toString().trim().toLowerCase() ??
            _multiKeyRoundRobin;
    if (strategy == _multiKeyRandom && available.length > 1) {
      final index = Random().nextInt(available.length);
      final selected = available[index];
      return _ProviderApiKeySelection(
        key: selected.key,
        itemId: selected.id,
        itemIndex: selected.index,
        strategy: strategy,
      );
    }

    if (strategy == _multiKeyExhaust) {
      final selected = _selectExhaustedKeyCandidate(
        items,
        (customConfig[_multiKeyRoundRobinIndexField] as num?)?.toInt() ?? 0,
      );
      return _ProviderApiKeySelection(
        key: selected.key,
        itemId: selected.id,
        itemIndex: selected.index,
        strategy: strategy,
      );
    }

    final providerId = providerAuth.id.trim();
    final current = _roundRobinIndexMap[providerId] ?? 0;
    final index = current % available.length;
    _roundRobinIndexMap[providerId] = (index + 1) % available.length;
    final selected = available[index];
    return _ProviderApiKeySelection(
      key: selected.key,
      itemId: selected.id,
      itemIndex: selected.index,
      strategy: strategy,
    );
  }

  _ProviderApiKeyCandidate _selectExhaustedKeyCandidate(
    List<_ProviderApiKeyCandidate> items,
    int currentIndex,
  ) {
    final normalizedIndex =
        items.isEmpty ? 0 : currentIndex.clamp(0, items.length - 1).toInt();
    for (var offset = 0; offset < items.length; offset++) {
      final index = (normalizedIndex + offset) % items.length;
      final item = items[index];
      if (item.enabled && !item.isError && item.key.isNotEmpty) {
        return item;
      }
    }
    for (var offset = 0; offset < items.length; offset++) {
      final index = (normalizedIndex + offset) % items.length;
      final item = items[index];
      if (item.enabled && item.key.isNotEmpty) {
        return item;
      }
    }
    return items.first;
  }

  Future<McpConfigDto?> getMcpConfig() async {
    final now = DateTime.now();
    if (_cachedMcpFetchedAt != null &&
        now.difference(_cachedMcpFetchedAt!) < McpApi.mobileConfigCacheTtl) {
      return _cachedMcpConfig;
    }
    try {
      final res = await _mcpApi.fetchConfig();
      _cachedMcpConfig = res.config;
      _cachedMcpFetchedAt = DateTime.now();
      return _cachedMcpConfig;
    } catch (_) {
      _cachedMcpConfig = null;
      _cachedMcpFetchedAt = DateTime.now();
      return null;
    }
  }

  Map<String, dynamic> buildToolPrefs(
      AppSettings settings, McpConfigDto? config) {
    final prefs = <String, dynamic>{
      'tts_enabled': settings.ttsEnabled,
    };
    if (config == null || !config.enabled || config.enabledTools.isEmpty) {
      prefs['auto_tools_enabled'] = false;
      return prefs;
    }
    prefs['auto_tools_enabled'] = true;
    prefs['mcp_enabled_tools'] = config.enabledTools;
    if (config.delegate.enabled) {
      final delegate = config.delegate;
      final delegateMap = <String, dynamic>{};
      if (delegate.provider != null && delegate.provider!.isNotEmpty) {
        delegateMap['provider'] = delegate.provider;
      }
      if (delegate.model != null && delegate.model!.isNotEmpty) {
        delegateMap['model'] = delegate.model;
      }
      if (delegate.apiBase != null && delegate.apiBase!.isNotEmpty) {
        delegateMap['api_base'] = delegate.apiBase;
      }
      if (delegate.prompt.isNotEmpty) {
        delegateMap['prompt'] = delegate.prompt;
      }
      if (delegateMap.isNotEmpty) {
        prefs['mcp_delegate'] = delegateMap;
      }
    }
    return prefs;
  }

  Future<ChatRequestConfig> buildRequestConfig(
    AppSettings settings, {
    String? modelRef,
  }) async {
    final mcpConfig = await getMcpConfig();
    final toolPrefs = buildToolPrefs(settings, mcpConfig);

    final resolvedModelRef = (modelRef != null && modelRef.trim().isNotEmpty)
        ? modelRef.trim()
        : settings.defaultModelName;

    final model = settings.getRawModelId(resolvedModelRef);
    final provider = settings.getModelProviderId(resolvedModelRef) ?? 'openai';
    var modelFull = '$provider:$model';

    final providerAuth = settings.providers.firstWhere(
      (p) => p.id == provider,
      orElse: () => ProviderAuth(
        id: provider,
        apiKeys: const <String>[],
        apiBaseUrl: settings.apiBaseUrl,
      ),
    );

    var providerApiBase = providerAuth.apiBaseUrl.trim().isEmpty
        ? settings.apiBaseUrl
        : providerAuth.apiBaseUrl.trim();
    final providerApiKeySelection = _selectProviderApiKey(providerAuth);
    var providerApiKey = providerApiKeySelection.key;

    try {
      final cfg = await direct.loadDirectConfig();
      if (cfg.enabled) {
        if ((providerApiBase.isEmpty ||
                providerApiBase == settings.apiBaseUrl) &&
            cfg.apiBase.isNotEmpty) {
          providerApiBase = cfg.apiBase;
        }
        if ((providerApiKey == null || providerApiKey.isEmpty) &&
            cfg.apiKey.isNotEmpty) {
          providerApiKey = cfg.apiKey;
        }
        if (!modelFull.contains(':') && cfg.model.isNotEmpty) {
          modelFull = 'openai:${cfg.model}';
        }
      }
    } catch (_) {}

    final modelConfig = settings.getModelConfig(resolvedModelRef);

    return ChatRequestConfig(
      modelRef: resolvedModelRef,
      modelFullId: modelFull,
      providerApiBase: providerApiBase,
      providerApiKey: providerApiKey?.isEmpty == true ? null : providerApiKey,
      providerId: provider,
      providerApiKeyItemId: providerApiKeySelection.itemId,
      providerApiKeyItemIndex: providerApiKeySelection.itemIndex,
      providerApiKeyStrategy: providerApiKeySelection.strategy,
      toolPrefs: toolPrefs,
      customConfig: providerAuth.customConfig,
      modelTemperature: modelConfig.temperature,
      modelTopP: modelConfig.topP,
      modelContextMessageLimit: modelConfig.contextMessageLimit,
    );
  }
}
