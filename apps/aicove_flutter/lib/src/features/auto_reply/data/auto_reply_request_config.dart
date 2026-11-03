import '../../chat/application/conversation_model.dart';
import '../../settings/app_settings.dart';
import '../../chat/services/chat_request_config.dart';

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

/// 从 [settings] 解析主动回复使用的聊天模型与供应商配置，
/// 并叠加直连模式（direct mode）兜底。[sessionModel] 是目标会话存的
/// `session_provider`，可用时优先，否则用默认队列首位。
Future<AutoReplyRequestConfig> resolveAutoReplyRequestConfig(
  AppSettings settings, {
  String? sessionModel,
}) async {
  final modelRef = sessionPrimaryModel(settings, sessionModel);
  // Availability probes must not consume the next real request's key.
  final request = await ChatRequestConfigBuilder().buildRequestConfig(
    settings,
    modelRef: modelRef,
    consumeKeyRotation: false,
  );

  return AutoReplyRequestConfig(
    modelFullId: request.modelFullId,
    providerApiBase: request.providerApiBase,
    providerApiKey: request.providerApiKey,
    customConfig: request.customConfig,
  );
}
