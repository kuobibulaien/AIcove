library;

const kGoogleVertexExpressField = 'vertexExpress';
const kGoogleVertexProviderId = 'vertex';
const kGoogleVertexProviderDisplayName = 'Google Gemini';
const kGoogleVertexProviderSplitMigrationId =
    'google_vertex_provider_split_20260331';
const kGeminiDeveloperApiBase =
    'https://generativelanguage.googleapis.com/v1beta';
const kGoogleGeminiProviderDisplayName = 'Google Gemini';
const kGeminiDeveloperDefaultModels = <String>[
  'gemini-2.5-flash',
  'gemini-2.5-pro',
  'gemini-2.5-flash-lite',
  'gemini-2.0-flash',
  'gemini-2.0-flash-lite',
  'gemini-3-flash-preview',
];
const kVertexExpressApiBase =
    'https://aiplatform.googleapis.com/v1/publishers/google';

const kVertexExpressDefaultModels = <String>[
  'gemini-2.5-pro',
  'gemini-2.5-flash',
  'gemini-2.5-flash-lite',
  'gemini-2.0-flash-001',
  'gemini-2.0-flash-lite-001',
];

bool isVertexExpressEnabled(Map<String, dynamic>? customConfig) {
  final raw = customConfig?[kGoogleVertexExpressField] ??
      customConfig?['vertex_express'];
  if (raw is bool) return raw;
  final normalized = raw?.toString().trim().toLowerCase();
  return normalized == 'true' || normalized == '1' || normalized == 'yes';
}

bool isVertexProviderId(String providerId) {
  final normalized = providerId.trim().toLowerCase();
  return normalized == kGoogleVertexProviderId ||
      normalized.startsWith('${kGoogleVertexProviderId}__');
}

bool isGoogleGeminiDeveloperApiBaseUrl(String? baseUrl) {
  final trimmed = baseUrl?.trim() ?? '';
  if (trimmed.isEmpty) return false;

  try {
    final uri = Uri.parse(trimmed);
    return uri.host.toLowerCase() == 'generativelanguage.googleapis.com';
  } catch (_) {
    return trimmed.toLowerCase().contains('generativelanguage.googleapis.com');
  }
}

bool isGoogleAiPlatformPublisherBaseUrl(String? baseUrl) {
  final trimmed = baseUrl?.trim() ?? '';
  if (trimmed.isEmpty) return false;

  try {
    final uri = Uri.parse(trimmed);
    final host = uri.host.toLowerCase();
    if (!host.endsWith('aiplatform.googleapis.com')) {
      return false;
    }
    final segments = uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .map((segment) => segment.toLowerCase())
        .toList(growable: false);
    final publishersIndex = segments.indexOf('publishers');
    if (publishersIndex < 0 || publishersIndex + 1 >= segments.length) {
      return false;
    }
    return segments[publishersIndex + 1] == 'google';
  } catch (_) {
    final normalized = trimmed.toLowerCase();
    return normalized.contains('aiplatform.googleapis.com') &&
        normalized.contains('/publishers/google');
  }
}

bool isGeminiProviderId(String providerId) {
  final normalized = providerId.trim().toLowerCase();
  return normalized == 'gemini' ||
      normalized == 'google' ||
      normalized.startsWith('gemini__') ||
      normalized.startsWith('google__');
}

Map<String, dynamic> ensureVertexProviderCustomConfig(
  Map<String, dynamic>? customConfig,
) {
  final next = Map<String, dynamic>.from(customConfig ?? const {});
  next['requestFormat'] = 'gemini';
  next[kGoogleVertexExpressField] = true;
  return next;
}

String googleSuggestedBaseUrl({required bool vertexExpress}) {
  return kGeminiDeveloperApiBase;
}

String normalizeGoogleModelId(
  String modelId, {
  required bool vertexExpress,
}) {
  var normalized = modelId.trim();
  if (normalized.isEmpty) return normalized;

  normalized = normalized.replaceFirst(
    RegExp(r':(streamGenerateContent|generateContent)$'),
    '',
  );

  const publisherPrefix = 'publishers/google/models/';
  if (normalized.startsWith(publisherPrefix)) {
    return normalized.substring(publisherPrefix.length);
  }

  if (normalized.startsWith('models/')) {
    return normalized.substring('models/'.length);
  }

  return normalized;
}

String buildGoogleGenerateContentEndpoint({
  required String baseUrl,
  required String model,
  required bool streaming,
  required bool vertexExpress,
}) {
  final normalizedBase = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  final fallbackModel = 'gemini-2.0-flash';
  final modelId = normalizeGoogleModelId(
    model.trim().isEmpty ? fallbackModel : model,
    vertexExpress: vertexExpress,
  );
  final operation = streaming ? 'streamGenerateContent' : 'generateContent';
  return '$normalizedBase/models/$modelId:$operation';
}

Uri buildGoogleRequestUri({
  required String endpoint,
  required bool vertexExpress,
  required String apiKey,
}) {
  final uri = Uri.parse(endpoint);
  if (!vertexExpress) {
    return uri;
  }
  return _appendGoogleApiKeyQuery(uri, apiKey);
}

Uri buildGooglePublisherModelsListUri({
  required String baseUrl,
  required String apiKey,
}) {
  final normalizedBase =
      (baseUrl.trim().isEmpty ? kGeminiDeveloperApiBase : baseUrl.trim());
  final uri = Uri.parse(normalizedBase.replaceAll(RegExp(r'/+$'), ''));
  final listUri = uri.replace(
    pathSegments: <String>[
      ...uri.pathSegments.where((segment) => segment.isNotEmpty),
      'models'
    ],
  );
  if (!isGoogleAiPlatformPublisherBaseUrl(baseUrl)) {
    return listUri;
  }
  return _appendGoogleApiKeyQuery(listUri, apiKey);
}

Uri _appendGoogleApiKeyQuery(Uri uri, String apiKey) {
  final trimmedKey = apiKey.trim();
  if (trimmedKey.isEmpty || uri.queryParameters.containsKey('key')) {
    return uri;
  }
  return uri.replace(
    queryParameters: <String, String>{
      ...uri.queryParameters,
      'key': trimmedKey,
    },
  );
}

String sanitizeGoogleRequestUrl(String url) {
  try {
    final uri = Uri.parse(url);
    if (!uri.queryParameters.containsKey('key')) {
      return url;
    }
    final nextQuery = <String, String>{...uri.queryParameters}..remove('key');
    return uri
        .replace(queryParameters: nextQuery.isEmpty ? null : nextQuery)
        .toString();
  } catch (_) {
    return url;
  }
}
