/// TTS 厂商上下文
///
/// 负责把 TTS 配置中的“已选渠道 + 已选模型”解析成 UI / 服务层可直接使用的
/// 统一上下文，避免页面层自己判断当前到底是哪家厂商。
library;

import '../../settings/app_settings.dart';
import '../../settings/settings_models.dart';
import 'providers/tts_provider_factory.dart';
import 'providers/tts_voice_provider.dart';
import 'tts_config.dart';

class TtsProviderContext {
  final TtsConfig config;
  final ProviderAuth? providerAuth;
  final TtsVoiceProvider? voiceProvider;
  final String? apiKey;
  final String requestFormat;
  final String? selectedModelId;

  const TtsProviderContext({
    required this.config,
    required this.providerAuth,
    required this.voiceProvider,
    required this.apiKey,
    required this.requestFormat,
    required this.selectedModelId,
  });

  TtsCapabilities? get capabilities => voiceProvider?.capabilities;

  String? get voiceProviderId => voiceProvider?.providerId;

  String? get providerDisplayName {
    final displayName = providerAuth?.displayName?.trim();
    if (displayName != null && displayName.isNotEmpty) {
      return displayName;
    }
    if (providerAuth != null && providerAuth!.id.trim().isNotEmpty) {
      return providerAuth!.id;
    }
    return voiceProvider?.displayName;
  }

  bool get hasConfiguredProvider => providerAuth != null;

  bool get hasVoiceProvider => voiceProvider != null;

  bool get hasApiKey => apiKey != null && apiKey!.trim().isNotEmpty;

  bool get canManageRemoteVoices => hasVoiceProvider && hasApiKey;

  static String? _resolveSelectedModelId(
    TtsConfig config,
    ProviderAuth? providerAuth,
  ) {
    final modelId = config.selectedModelId?.trim();
    if (modelId == null || modelId.isEmpty) return null;
    if (providerAuth == null) return null;
    if (providerAuth.visibleModels.contains(modelId) ||
        providerAuth.models.contains(modelId)) {
      return modelId;
    }
    return null;
  }

  static TtsProviderContext resolve({
    required TtsConfig config,
    required AppSettings? settings,
  }) {
    final providerId = config.selectedProviderId?.trim();
    final providerAuth = providerId == null || providerId.isEmpty
        ? null
        : settings?.getProvider(providerId);
    final rawRequestFormat =
        providerAuth?.customConfig['requestFormat']?.toString();
    final resolution = providerAuth == null
        ? const TtsProviderResolution(
            voiceProvider: null,
            requestFormat: 'openai_tts',
          )
        : TtsProviderFactory.resolve(
            providerId: providerAuth.id,
            apiUrl: providerAuth.apiBaseUrl,
            requestFormat: rawRequestFormat,
          );
    final apiKey = providerAuth?.apiKeys.isNotEmpty == true
        ? providerAuth!.apiKeys.first.trim()
        : null;

    return TtsProviderContext(
      config: config,
      providerAuth: providerAuth,
      voiceProvider: resolution.voiceProvider,
      apiKey: apiKey,
      requestFormat: resolution.requestFormat,
      selectedModelId: _resolveSelectedModelId(config, providerAuth),
    );
  }
}
