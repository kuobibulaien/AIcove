import '../../settings/app_settings.dart';
import '../../settings/direct_mode.dart' as direct;

/// 主动回复后台执行所需的模型请求配置。
///
/// 决策（2026-06-13）：WorkManager inputData 不再携带 apiKey/model 等
/// 配置快照，统一在任务执行时通过本解析器现读最新设置——
/// 避免密钥落地到 WorkManager 持久化，也避免用户换 key/换模型后
/// 旧任务仍带着过期配置执行。
class AutoReplyRequestConfig {
  const AutoReplyRequestConfig({
    required this.modelFullId,
    required this.providerApiBase,
    required this.providerApiKey,
    required this.customConfig,
  });

  final String modelFullId;
  final String providerApiBase;
  final String? providerApiKey;
  final Map<String, dynamic> customConfig;
}

/// 从 [settings] 解析主动回复使用的默认聊天模型与供应商配置，
/// 并叠加直连模式（direct mode）兜底。
Future<AutoReplyRequestConfig> resolveAutoReplyRequestConfig(
  AppSettings settings,
) async {
  final modelRef = settings.defaultChatModels.isNotEmpty
      ? settings.defaultChatModels.first
      : settings.defaultModelName;
  final providerId = settings.getModelProviderId(modelRef) ?? 'openai';
  var modelFullId = settings.toModelFullId(
    modelRef,
    fallbackProvider: providerId,
  );

  final providerAuth = settings.providers.firstWhere(
    (provider) => provider.id == providerId,
    orElse: () => ProviderAuth(
      id: providerId,
      apiKeys: const <String>[],
      apiBaseUrl: settings.apiBaseUrl,
    ),
  );

  var providerApiBase = providerAuth.apiBaseUrl.trim().isEmpty
      ? settings.apiBaseUrl
      : providerAuth.apiBaseUrl.trim();
  String? providerApiKey = providerAuth.apiKeys.isNotEmpty
      ? providerAuth.apiKeys.first.trim()
      : null;

  try {
    final directConfig = await direct.loadDirectConfig();
    if (directConfig.enabled) {
      if ((providerApiBase.isEmpty || providerApiBase == settings.apiBaseUrl) &&
          directConfig.apiBase.trim().isNotEmpty) {
        providerApiBase = directConfig.apiBase.trim();
      }
      if ((providerApiKey == null || providerApiKey.isEmpty) &&
          directConfig.apiKey.trim().isNotEmpty) {
        providerApiKey = directConfig.apiKey.trim();
      }
      if (!modelFullId.contains(':') && directConfig.model.trim().isNotEmpty) {
        modelFullId = 'openai:${directConfig.model.trim()}';
      }
    }
  } catch (_) {}

  return AutoReplyRequestConfig(
    modelFullId: modelFullId,
    providerApiBase: providerApiBase,
    providerApiKey: providerApiKey == null || providerApiKey.isEmpty
        ? null
        : providerApiKey,
    customConfig: providerAuth.customConfig,
  );
}
