library;

const kGoogleVertexExpressField = 'vertexExpress';
const kGeminiDeveloperApiBase =
    'https://generativelanguage.googleapis.com/v1beta';
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

String googleSuggestedBaseUrl({required bool vertexExpress}) {
  return vertexExpress ? kVertexExpressApiBase : kGeminiDeveloperApiBase;
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

  if (vertexExpress) {
    const publisherPrefix = 'publishers/google/models/';
    if (normalized.startsWith(publisherPrefix)) {
      return normalized.substring(publisherPrefix.length);
    }
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
  final fallbackModel =
      vertexExpress ? 'gemini-2.0-flash-001' : 'gemini-2.0-flash';
  final modelId = normalizeGoogleModelId(
    model.trim().isEmpty ? fallbackModel : model,
    vertexExpress: vertexExpress,
  );
  final operation = streaming ? 'streamGenerateContent' : 'generateContent';

  if (!vertexExpress) {
    return '$normalizedBase/models/$modelId:$operation';
  }

  if (normalizedBase.endsWith('/publishers/google/models')) {
    return '$normalizedBase/$modelId:$operation';
  }
  if (normalizedBase.endsWith('/publishers/google')) {
    return '$normalizedBase/models/$modelId:$operation';
  }
  return '$normalizedBase/publishers/google/models/$modelId:$operation';
}

Uri buildGoogleRequestUri({
  required String endpoint,
  required bool vertexExpress,
  required String apiKey,
}) {
  final uri = Uri.parse(endpoint);
  if (!vertexExpress) return uri;

  final trimmedKey = apiKey.trim();
  if (trimmedKey.isEmpty) return uri;

  final query = <String, String>{...uri.queryParameters, 'key': trimmedKey};
  return uri.replace(queryParameters: query);
}

Uri buildGooglePublisherModelsListUri({
  required String baseUrl,
  required String apiKey,
}) {
  final normalizedBase =
      (baseUrl.trim().isEmpty ? kVertexExpressApiBase : baseUrl.trim());
  final uri = Uri.parse(normalizedBase);
  final segments = uri.pathSegments.where((segment) => segment.isNotEmpty);
  final pathSegments = segments.toList();
  final publishersIndex = pathSegments.indexOf('publishers');
  final prefix = publishersIndex >= 0
      ? pathSegments.sublist(0, publishersIndex)
      : List<String>.from(pathSegments);

  if (prefix.isEmpty) {
    prefix.add('v1beta1');
  } else {
    final version = prefix.last.toLowerCase();
    if (version == 'v1' || version == 'v1beta' || version == 'v1beta1') {
      prefix[prefix.length - 1] = 'v1beta1';
    } else {
      prefix.add('v1beta1');
    }
  }

  final query = <String, String>{
    ...uri.queryParameters,
    if (apiKey.trim().isNotEmpty) 'key': apiKey.trim(),
  };

  return uri.replace(
    pathSegments: <String>[
      ...prefix,
      'publishers',
      'google',
      'models',
    ],
    queryParameters: query.isEmpty ? null : query,
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
