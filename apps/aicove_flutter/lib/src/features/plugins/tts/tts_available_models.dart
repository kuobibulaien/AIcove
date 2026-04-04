import '../../settings/app_settings.dart';
import '../../settings/settings_models.dart';
import 'providers/tts_provider_factory.dart';

class TtsAvailableModelEntry {
  final String modelId;
  final String providerId;
  final String providerName;
  final String displayName;
  final String? voiceProviderId;

  const TtsAvailableModelEntry({
    required this.modelId,
    required this.providerId,
    required this.providerName,
    required this.displayName,
    this.voiceProviderId,
  });
}

List<TtsAvailableModelEntry> buildConfiguredTtsModels(AppSettings? settings) {
  if (settings == null) return const <TtsAvailableModelEntry>[];

  final ttsModels = <TtsAvailableModelEntry>[];
  for (final provider in settings.providers) {
    if (!_isConfiguredTtsProvider(provider)) continue;

    for (final modelId in settings.getProviderVisibleModelsByType(
      provider.id,
      type: ModelType.tts,
    )) {
      final resolution = TtsProviderFactory.resolve(
        providerId: provider.id,
        apiUrl: provider.apiBaseUrl,
        requestFormat: provider.customConfig['requestFormat']?.toString(),
      );
      final modelRef = settings.buildModelRef(provider.id, modelId);
      ttsModels.add(
        TtsAvailableModelEntry(
          modelId: modelId,
          providerId: provider.id,
          providerName: provider.displayName ?? provider.id,
          displayName: settings.getModelDisplayName(modelRef),
          voiceProviderId: resolution.voiceProvider?.providerId,
        ),
      );
    }
  }
  return ttsModels;
}

bool _isConfiguredTtsProvider(ProviderAuth provider) {
  if (!provider.enabled) return false;
  if (provider.apiKeys.every((item) => item.trim().isEmpty)) {
    return false;
  }
  return provider.capabilities.contains('tts');
}
