import '../../../core/api/providers/google_api_mode.dart';
import '../../../core/api/providers/provider_adapter_factory.dart';
import '../../../core/api/providers/provider_chat_api_path.dart';
import '../app_settings.dart';

const providerMultiKeyEnabledField = 'multi_key_enabled';
const providerMultiKeyStrategyField = 'multi_key_strategy';
const providerMultiKeyItemsField = 'multi_key_items';
const providerMultiKeyRoundRobinIndexField = 'multi_key_rr_index';
const providerMultiKeyStrategyRoundRobin = 'round_robin';
const providerMultiKeyStrategyRandom = 'random';

enum ProviderMultiKeyStatus { normal, error }

class ProviderDetailRequestFormat {
  const ProviderDetailRequestFormat._(this.value, this.label);

  static const openai = ProviderDetailRequestFormat._('openai', 'OpenAI');
  static const claude = ProviderDetailRequestFormat._('claude', 'Claude');
  static const gemini = ProviderDetailRequestFormat._('gemini', 'Gemini');
  static const novelai = ProviderDetailRequestFormat._('novelai', 'NovelAI');

  static const chatFormats = <ProviderDetailRequestFormat>[
    openai,
    claude,
    gemini,
  ];
  static const imageFormats = <ProviderDetailRequestFormat>[openai, novelai];

  final String value;
  final String label;

  static List<ProviderDetailRequestFormat> forProvider(
    ProviderAuth provider, {
    AppSettings? settings,
  }) {
    final current = fromRaw(provider.customConfig['requestFormat']?.toString());
    if (current == ProviderDetailRequestFormat.novelai) {
      return imageFormats;
    }
    if (settings == null) {
      return chatFormats;
    }
    final imageModels =
        settings.getProviderModelsByType(provider.id, type: ModelType.image);
    final hasImageModel = imageModels.isNotEmpty;
    final hasNonImageModel = provider.models.any((modelId) {
      final modelRef = settings.buildModelRef(provider.id, modelId);
      return settings.getModelType(modelRef) != ModelType.image;
    });
    final isImageProvider = hasImageModel && !hasNonImageModel;
    return isImageProvider ? imageFormats : chatFormats;
  }

  static ProviderDetailRequestFormat? fromRaw(String? raw) {
    final normalized = raw?.trim().toLowerCase();
    switch (normalized) {
      case 'openai':
        return ProviderDetailRequestFormat.openai;
      case 'claude':
      case 'anthropic':
        return ProviderDetailRequestFormat.claude;
      case 'gemini':
      case 'google':
        return ProviderDetailRequestFormat.gemini;
      case 'novelai':
      case 'nai':
        return ProviderDetailRequestFormat.novelai;
      default:
        return null;
    }
  }
}

ProviderDetailRequestFormat resolveProviderDetailRequestFormat(
  ProviderAuth provider, {
  AppSettings? settings,
}) {
  final available = ProviderDetailRequestFormat.forProvider(
    provider,
    settings: settings,
  );
  final fromConfig = ProviderDetailRequestFormat.fromRaw(
    provider.customConfig['requestFormat']?.toString(),
  );
  if (fromConfig != null && available.contains(fromConfig)) {
    return fromConfig;
  }

  final fromId = ProviderDetailRequestFormat.fromRaw(provider.id);
  if (fromId != null && available.contains(fromId)) return fromId;

  return available.first;
}

bool isProviderDetailVertexExpressMode(ProviderAuth provider) {
  final requestFormat = ProviderDetailRequestFormat.fromRaw(
    provider.customConfig['requestFormat']?.toString(),
  );
  if (requestFormat != null &&
      requestFormat != ProviderDetailRequestFormat.gemini) {
    return false;
  }
  return isVertexExpressEnabled(provider.customConfig);
}

String resolveProviderDetailChatProvider(ProviderAuth provider) {
  return ProviderAdapterFactory.resolveProvider(
    provider.id,
    customConfig: provider.customConfig,
    apiBaseUrl: provider.apiBaseUrl,
  );
}

String defaultProviderDetailChatApiPathForFormat(
  ProviderDetailRequestFormat format,
) {
  return defaultChatApiPathForProvider(format.value);
}

String resolveProviderDetailChatApiPath(ProviderAuth provider) {
  return resolveProviderChatApiPath(
    resolveProviderDetailChatProvider(provider),
    customConfig: provider.customConfig,
  );
}

class ProviderMultiKeyItem {
  const ProviderMultiKeyItem({
    required this.id,
    required this.key,
    this.alias,
    this.enabled = true,
    this.status = ProviderMultiKeyStatus.normal,
    this.totalRequests = 0,
    this.successRequests = 0,
    this.failedRequests = 0,
    this.consecutiveFailures = 0,
    this.lastUsedAt,
    this.lastError,
    required this.updatedAt,
  });

  final String id;
  final String key;
  final String? alias;
  final bool enabled;
  final ProviderMultiKeyStatus status;
  final int totalRequests;
  final int successRequests;
  final int failedRequests;
  final int consecutiveFailures;
  final int? lastUsedAt;
  final String? lastError;
  final int updatedAt;

  static String createId() =>
      'mk_${DateTime.now().microsecondsSinceEpoch.toString()}';

  factory ProviderMultiKeyItem.fromJson(
    Map<String, dynamic> json, {
    int index = 0,
  }) {
    final rawStatus = json['status']?.toString().trim().toLowerCase();
    final status = rawStatus == 'error'
        ? ProviderMultiKeyStatus.error
        : ProviderMultiKeyStatus.normal;
    final rawId = json['id']?.toString().trim();
    final key = json['key']?.toString().trim() ?? '';
    final id = (rawId == null || rawId.isEmpty)
        ? 'legacy_${index}_${key.hashCode.abs()}'
        : rawId;
    return ProviderMultiKeyItem(
      id: id,
      key: key,
      alias: json['alias']?.toString().trim(),
      enabled: json['enabled'] != false,
      status: status,
      totalRequests: (json['total_requests'] as num?)?.toInt() ?? 0,
      successRequests: (json['success_requests'] as num?)?.toInt() ?? 0,
      failedRequests: (json['failed_requests'] as num?)?.toInt() ?? 0,
      consecutiveFailures: (json['consecutive_failures'] as num?)?.toInt() ?? 0,
      lastUsedAt: (json['last_used_at'] as num?)?.toInt(),
      lastError: json['last_error']?.toString(),
      updatedAt: (json['updated_at'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
    );
  }

  factory ProviderMultiKeyItem.fromKey(String key, {int index = 0}) {
    final trimmed = key.trim();
    final now = DateTime.now().millisecondsSinceEpoch;
    return ProviderMultiKeyItem(
      id: 'legacy_${index}_${trimmed.hashCode.abs()}',
      key: trimmed,
      updatedAt: now,
    );
  }

  ProviderMultiKeyItem copyWith({
    String? id,
    String? key,
    String? alias,
    bool? enabled,
    ProviderMultiKeyStatus? status,
    int? totalRequests,
    int? successRequests,
    int? failedRequests,
    int? consecutiveFailures,
    int? lastUsedAt,
    String? lastError,
    int? updatedAt,
    bool clearAlias = false,
    bool clearLastError = false,
    bool clearLastUsedAt = false,
  }) {
    return ProviderMultiKeyItem(
      id: id ?? this.id,
      key: key ?? this.key,
      alias: clearAlias ? null : (alias ?? this.alias),
      enabled: enabled ?? this.enabled,
      status: status ?? this.status,
      totalRequests: totalRequests ?? this.totalRequests,
      successRequests: successRequests ?? this.successRequests,
      failedRequests: failedRequests ?? this.failedRequests,
      consecutiveFailures: consecutiveFailures ?? this.consecutiveFailures,
      lastUsedAt: clearLastUsedAt ? null : (lastUsedAt ?? this.lastUsedAt),
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'key': key,
        'alias': alias,
        'enabled': enabled,
        'status': status == ProviderMultiKeyStatus.error ? 'error' : 'normal',
        'total_requests': totalRequests,
        'success_requests': successRequests,
        'failed_requests': failedRequests,
        'consecutive_failures': consecutiveFailures,
        'last_used_at': lastUsedAt,
        'last_error': lastError,
        'updated_at': updatedAt,
      };
}

class ProviderMultiKeyFormResult {
  const ProviderMultiKeyFormResult({
    required this.key,
    this.alias,
  });

  final String key;
  final String? alias;
}

bool isProviderMultiKeyEnabled(ProviderAuth provider) =>
    provider.customConfig[providerMultiKeyEnabledField] == true;

String providerMultiKeyStrategy(ProviderAuth provider) {
  final raw =
      provider.customConfig[providerMultiKeyStrategyField]?.toString().trim();
  if (raw == null || raw.isEmpty) return providerMultiKeyStrategyRoundRobin;
  return raw;
}

String providerMultiKeyStrategyLabel(String strategy) {
  switch (strategy.trim().toLowerCase()) {
    case providerMultiKeyStrategyRoundRobin:
      return '轮询';
    case providerMultiKeyStrategyRandom:
      return '随机';
    default:
      return strategy.trim().isEmpty ? '轮询' : strategy.trim();
  }
}

List<ProviderMultiKeyItem> providerMultiKeyItemsFromProvider(
  ProviderAuth provider,
) {
  final out = <ProviderMultiKeyItem>[];
  final rawList = provider.customConfig[providerMultiKeyItemsField];
  if (rawList is List) {
    for (var i = 0; i < rawList.length; i++) {
      final item = rawList[i];
      if (item is! Map) continue;
      final parsed = ProviderMultiKeyItem.fromJson(
        Map<String, dynamic>.from(item),
        index: i,
      );
      if (parsed.key.isEmpty) continue;
      out.add(parsed);
    }
  }
  if (out.isNotEmpty) return out;

  final fallback = <ProviderMultiKeyItem>[];
  for (var i = 0; i < provider.apiKeys.length; i++) {
    final key = provider.apiKeys[i].trim();
    if (key.isEmpty) continue;
    fallback.add(ProviderMultiKeyItem.fromKey(key, index: i));
  }
  return fallback;
}

List<String> extractApiKeysFromProviderMultiKeyItems(
  List<ProviderMultiKeyItem> items,
) {
  final out = <String>[];
  for (final item in items) {
    final key = item.key.trim();
    if (key.isEmpty || out.contains(key)) continue;
    out.add(key);
  }
  return out;
}

Map<String, dynamic> buildProviderCustomConfigForMultiKey({
  required ProviderAuth provider,
  bool? enabled,
  String? strategy,
  List<ProviderMultiKeyItem>? items,
  int? roundRobinIndex,
}) {
  final config = Map<String, dynamic>.from(provider.customConfig);
  if (enabled != null) {
    config[providerMultiKeyEnabledField] = enabled;
  }
  if (strategy != null && strategy.trim().isNotEmpty) {
    config[providerMultiKeyStrategyField] = strategy.trim();
  }
  if (items != null) {
    config[providerMultiKeyItemsField] = items.map((e) => e.toJson()).toList();
  }
  if (roundRobinIndex != null) {
    config[providerMultiKeyRoundRobinIndexField] = roundRobinIndex;
  }
  return config;
}

String maskProviderMultiKeyValue(String key) {
  final value = key.trim();
  if (value.length <= 8) return value;
  return '${value.substring(0, 4)}••••${value.substring(value.length - 4)}';
}
