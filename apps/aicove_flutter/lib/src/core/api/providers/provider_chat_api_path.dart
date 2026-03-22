library;

const kProviderChatApiPathField = 'apiPath';
const kProviderChatModelPlaceholder = '{model}';

const String _kGeminiGenerateContentSuffix = ':generateContent';
const String _kGeminiStreamGenerateContentSuffix = ':streamGenerateContent';

String defaultChatApiPathForProvider(String provider) {
  switch (provider.trim().toLowerCase()) {
    case 'claude':
    case 'anthropic':
      return '/messages';
    case 'gemini':
    case 'google':
      return '/models/$kProviderChatModelPlaceholder:generateContent';
    case 'minimax':
      return '';
    case 'openai':
    default:
      return '/chat/completions';
  }
}

String resolveProviderChatApiPath(
  String provider, {
  Map<String, dynamic>? customConfig,
}) {
  final custom = normalizeProviderChatApiPath(
    customConfig?[kProviderChatApiPathField]?.toString(),
  );
  if (custom != null) return custom;
  return defaultChatApiPathForProvider(provider);
}

String? normalizeProviderChatApiPath(String? raw) {
  final trimmed = raw?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  if (_looksLikeAbsoluteUrl(trimmed)) {
    return trimmed.replaceAll(RegExp(r'/+$'), '');
  }
  return trimmed.startsWith('/') ? trimmed : '/$trimmed';
}

Map<String, dynamic> copyCustomConfigWithProviderChatApiPath(
  Map<String, dynamic> customConfig,
  String? apiPath,
) {
  final next = Map<String, dynamic>.from(customConfig);
  final normalized = normalizeProviderChatApiPath(apiPath);
  if (normalized == null || normalized.isEmpty) {
    next.remove(kProviderChatApiPathField);
  } else {
    next[kProviderChatApiPathField] = normalized;
  }
  return next;
}

String buildProviderChatEndpoint({
  required String provider,
  required String apiBaseUrl,
  required String model,
  Map<String, dynamic>? customConfig,
  bool streaming = false,
}) {
  final base = apiBaseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  final path = buildProviderChatPath(
    provider: provider,
    model: model,
    customConfig: customConfig,
    streaming: streaming,
  );
  if (path.isEmpty) return base;
  if (_looksLikeAbsoluteUrl(path)) return path;
  if (provider.trim().toLowerCase() == 'gemini' &&
      _isVertexExpressEnabled(customConfig)) {
    return _joinGeminiVertexBaseAndPath(base, path);
  }
  if (base.isEmpty) return path;
  return '$base${path.startsWith('/') ? path : '/$path'}';
}

String buildProviderChatPath({
  required String provider,
  required String model,
  Map<String, dynamic>? customConfig,
  bool streaming = false,
}) {
  var path = resolveProviderChatApiPath(
    provider,
    customConfig: customConfig,
  );
  if (path.isEmpty) return path;

  final trimmedModel = model.trim();
  if (path.contains(kProviderChatModelPlaceholder) && trimmedModel.isNotEmpty) {
    path = path.replaceAll(kProviderChatModelPlaceholder, trimmedModel);
  }

  if (provider.trim().toLowerCase() == 'gemini') {
    if (streaming) {
      if (path.contains(_kGeminiGenerateContentSuffix)) {
        path = path.replaceFirst(
          _kGeminiGenerateContentSuffix,
          _kGeminiStreamGenerateContentSuffix,
        );
      } else if (!path.contains(_kGeminiStreamGenerateContentSuffix)) {
        path = '$path$_kGeminiStreamGenerateContentSuffix';
      }
    } else if (path.contains(_kGeminiStreamGenerateContentSuffix)) {
      path = path.replaceFirst(
        _kGeminiStreamGenerateContentSuffix,
        _kGeminiGenerateContentSuffix,
      );
    } else if (!path.contains(_kGeminiGenerateContentSuffix)) {
      path = '$path$_kGeminiGenerateContentSuffix';
    }
  }

  return path;
}

bool shouldSuggestOpenAiBaseUrlV1(String apiBaseUrl) {
  return !apiBaseUrl.trim().toLowerCase().endsWith('/v1');
}

bool _isVertexExpressEnabled(Map<String, dynamic>? customConfig) {
  final raw = customConfig?['vertexExpress'] ?? customConfig?['vertex_express'];
  if (raw is bool) return raw;
  final normalized = raw?.toString().trim().toLowerCase();
  return normalized == 'true' || normalized == '1' || normalized == 'yes';
}

String _joinGeminiVertexBaseAndPath(String base, String path) {
  if (base.isEmpty) return path;
  if (path.startsWith('/publishers/google/models/')) {
    return '$base$path';
  }
  if (base.endsWith('/publishers/google/models') &&
      path.startsWith('/models/')) {
    return '$base/${path.substring('/models/'.length)}';
  }
  if (base.endsWith('/publishers/google')) {
    return '$base${path.startsWith('/') ? path : '/$path'}';
  }
  if (path.startsWith('/models/')) {
    return '$base/publishers/google$path';
  }
  return '$base${path.startsWith('/') ? path : '/$path'}';
}

bool _looksLikeAbsoluteUrl(String value) {
  final normalized = value.trim().toLowerCase();
  return normalized.startsWith('https://') || normalized.startsWith('http://');
}
