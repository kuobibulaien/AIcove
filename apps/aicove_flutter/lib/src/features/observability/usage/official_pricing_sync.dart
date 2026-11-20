part of 'model_pricing_catalog.dart';

class OfficialPricingSyncResult {
  const OfficialPricingSyncResult({
    required this.modelCount,
    required this.syncedAt,
  });

  final int modelCount;
  final DateTime syncedAt;
}

/// Device-local price caches. Reading them never contacts the network.
class ModelPricingCatalog {
  ModelPricingCatalog._();

  static const _providerCacheKey =
      'aicove.observability.provider_pricing_cache.v1';
  static const _officialCacheKey =
      'aicove.observability.official_pricing_cache.v1';
  static const _firstPartyProviders = {
    'openai',
    'anthropic',
    'google',
    'google-vertex',
    'google-vertex-anthropic',
    'deepseek',
    'moonshotai',
    'zhipuai',
    'alibaba',
    'alibaba-cn',
    'xai',
    'minimax',
    'stepfun',
    'xiaomi',
    'inception',
    'volcengine',
    'bytedance',
    'meta',
    'mistral',
    'cohere',
    'qwen',
  };

  static final _providerPrices = <String, ModelPricing>{};
  static Map<String, _OfficialPrice> _officialPrices = {};
  static DateTime? _lastOfficialSyncAt;
  static DateTime? get lastOfficialPricingSyncAt => _lastOfficialSyncAt;
  static Future<void>? _loading;

  static Future<void> loadLocalCaches() => _loading ??= _loadLocalCaches();

  static Future<void> _loadLocalCaches() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final entry in _decodeMap(
        prefs.getString(_providerCacheKey),
      ).entries) {
        final price = _readPricing(entry.value);
        // A freshly received /models price takes precedence over disk.
        if (price != null) _providerPrices.putIfAbsent(entry.key, () => price);
      }
      final official = _decodeMap(prefs.getString(_officialCacheKey));
      final syncedAt = official['syncedAt'];
      if (syncedAt is String) _lastOfficialSyncAt = DateTime.tryParse(syncedAt);
      final prices = official['prices'];
      if (prices is Map) {
        for (final entry in prices.entries) {
          final value = entry.value;
          if (value is! Map || value['priority'] is! int) continue;
          final price = _readPricing(value);
          if (price != null) {
            _officialPrices[entry.key as String] = (
              price: price,
              priority: value['priority'] as int,
            );
          }
        }
      }
    } catch (_) {
      _loading = null;
      rethrow;
    }
  }

  static String _providerKey(String providerId, String normalizedId) =>
      '${providerId.trim().toLowerCase()}:$normalizedId';

  /// Publishes a list response in memory immediately, then saves it locally.
  static Future<void> cacheProviderPricing(
    String providerId,
    Map<String, Map> pricingByModel,
  ) async {
    var hasPrices = false;
    for (final entry in pricingByModel.entries) {
      final id = normalizeModelIdForPricing(entry.key);
      if (id.isEmpty) continue;
      final price = _readPricing(entry.value, perToken: true);
      if (price == null) continue;
      _providerPrices[_providerKey(providerId, id)] = price;
      hasPrices = true;
    }
    if (!hasPrices) return;
    await loadLocalCaches();
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setString(
      _providerCacheKey,
      jsonEncode(
        _providerPrices.map((key, price) => MapEntry(key, _priceJson(price))),
      ),
    );
    if (!saved) throw StateError('Could not save provider pricing cache');
  }

  static Future<OfficialPricingSyncResult> syncOfficialPricingCatalog({
    ApiClient? apiClient,
  }) async {
    await loadLocalCaches();
    const url = 'https://models.dev/api.json';
    final client = apiClient == null ? http.Client() : null;
    final Map<String, dynamic> data;
    try {
      data =
          await (apiClient ??
                  ApiClient(
                    client: client,
                    timeout: const Duration(seconds: 15),
                  ))
              .getJson(url);
    } finally {
      client?.close();
    }
    final next = <String, _OfficialPrice>{};
    final modelIds = <String>{};
    for (final provider in data.entries) {
      final value = provider.value;
      final models = value is Map ? value['models'] : null;
      if (models is! Map) continue;
      final firstParty = _firstPartyProviders.contains(provider.key);
      for (final model in models.entries) {
        final rawId = (model.key as String).trim().toLowerCase();
        final id = normalizeModelIdForPricing(rawId);
        if (id.isEmpty || model.value is! Map) continue;
        final price = _readPricing((model.value as Map)['cost']);
        if (price == null) continue;
        final paid =
            price.inputPricePerMillion > 0 || price.outputPricePerMillion > 0;
        final priority = firstParty
            ? (paid ? 3 : 2)
            : paid
            ? 1
            : 0;
        if (priority == 0 && !(id.endsWith(':free') || id.endsWith('-free'))) {
          continue;
        }
        modelIds.add(id);
        for (final alias in _officialAliases(rawId)) {
          if ((next[alias]?.priority ?? -1) < priority) {
            next[alias] = (price: price, priority: priority);
          }
        }
      }
    }
    if (modelIds.isEmpty) {
      throw const FormatException('No model prices in pricing catalog');
    }

    final syncedAt = DateTime.now().toUtc();
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setString(
      _officialCacheKey,
      jsonEncode({
        'syncedAt': syncedAt.toIso8601String(),
        'prices': next.map(
          (id, entry) => MapEntry(id, {
            ..._priceJson(entry.price),
            'priority': entry.priority,
          }),
        ),
      }),
    );
    if (!saved) throw StateError('Could not save official pricing cache');
    _officialPrices = next;
    _lastOfficialSyncAt = syncedAt;
    return OfficialPricingSyncResult(
      modelCount: modelIds.length,
      syncedAt: syncedAt,
    );
  }

  static Set<String> _officialAliases(String rawId) {
    final raw = rawId.trim().toLowerCase();
    return {raw, raw.split('/').last, normalizeModelIdForPricing(raw)};
  }

  static ModelPricing? _lookupOfficial(String modelId) {
    _OfficialPrice? best;
    for (final alias in _officialAliases(modelId)) {
      final candidate = _officialPrices[alias];
      if (candidate != null &&
          (best == null || candidate.priority > best.priority)) {
        best = candidate;
      }
    }
    return best?.price;
  }

  static Map<String, dynamic> _decodeMap(String? raw) {
    if (raw == null) return {};
    try {
      final value = jsonDecode(raw);
      return value is Map<String, dynamic> ? value : {};
    } on FormatException {
      return {};
    }
  }

  static ModelPricing? _readPricing(Object? raw, {bool perToken = false}) {
    if (raw is! Map) return null;

    double? read(String key) {
      final parsed = double.tryParse('${raw[key]}');
      if (parsed == null || !parsed.isFinite || parsed < 0) return null;
      if (!perToken) return parsed;
      return parsed <= .05 ? parsed * 1000000 : null;
    }

    final input = read(perToken ? 'prompt' : 'input');
    final output = read(perToken ? 'completion' : 'output');
    if (input == null || output == null) return null;
    final write = read(perToken ? 'input_cache_write' : 'cache_write');
    return ModelPricing(
      inputPricePerMillion: input,
      outputPricePerMillion: output,
      cachedInputPricePerMillion: read(
        perToken ? 'input_cache_read' : 'cache_read',
      ),
      cacheWritePricePerMillion: write == 0 && input > 0 ? null : write,
      isBuiltinReference: true,
    );
  }

  static Map<String, double?> _priceJson(ModelPricing price) => {
    'input': price.inputPricePerMillion,
    'output': price.outputPricePerMillion,
    'cache_read': price.cachedInputPricePerMillion,
    'cache_write': price.cacheWritePricePerMillion,
  };
}

typedef _OfficialPrice = ({ModelPricing price, int priority});

/// Drops in-memory state; tests control persisted state via SharedPreferences.
void resetModelPricingCachesForTesting() {
  ModelPricingCatalog._providerPrices.clear();
  ModelPricingCatalog._officialPrices = {};
  ModelPricingCatalog._lastOfficialSyncAt = null;
  ModelPricingCatalog._loading = null;
}
