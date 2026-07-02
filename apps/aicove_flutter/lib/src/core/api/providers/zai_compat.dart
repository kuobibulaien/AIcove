library;

const kZaiGeneralApiBase = 'https://api.z.ai/api/paas/v4';
const kZaiCodingApiBase = 'https://api.z.ai/api/coding/paas/v4';
const kZaiProviderBackfillMigrationId = 'builtin_provider_zai_20260322';

const kZaiDefaultChatModels = <String>[
  'glm-5',
  'glm-5-turbo',
  'glm-4.7',
  'glm-4.7-flash',
  'glm-4.7-flashx',
  'glm-4.6',
  'glm-4.5',
  'glm-4.5-air',
];

const _zaiProviderAliases = <String>[
  'zai',
  'z.ai',
  'glm',
  'zhipu',
];

bool isZaiProviderId(String? value) {
  final normalized = value?.trim().toLowerCase() ?? '';
  if (normalized.isEmpty) return false;
  for (final alias in _zaiProviderAliases) {
    if (normalized == alias || normalized.startsWith('${alias}__')) {
      return true;
    }
  }
  return false;
}

bool isZaiApiUrl(String? value) {
  final raw = value?.trim() ?? '';
  if (raw.isEmpty) return false;

  try {
    final uri = Uri.parse(raw);
    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();
    if (host != 'api.z.ai') return false;
    return path.contains('/api/paas/v4') ||
        path.contains('/api/coding/paas/v4');
  } catch (_) {
    final normalized = raw.toLowerCase();
    return normalized.contains('api.z.ai/api/paas/v4') ||
        normalized.contains('api.z.ai/api/coding/paas/v4');
  }
}

bool isZaiProvider({
  required String providerId,
  String? apiBaseUrl,
}) {
  return isZaiProviderId(providerId) || isZaiApiUrl(apiBaseUrl);
}
