import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/providers/provider_chat_api_path.dart';
import '../app_settings.dart';
import 'provider_detail_support.dart';

final providerDetailActionsProvider = Provider<ProviderDetailActions>(
  ProviderDetailActions.new,
);

class ProviderDetailActions {
  const ProviderDetailActions(this._ref);

  final Ref _ref;

  AppSettingsNotifier get _notifier => _ref.read(appSettingsProvider.notifier);
  AppSettings? get _settings => _ref.read(appSettingsProvider).valueOrNull;

  String resolvePrimaryApiKey(ProviderAuth provider) {
    final fallback =
        provider.apiKeys.isNotEmpty ? provider.apiKeys.first.trim() : '';
    if (!isProviderMultiKeyEnabled(provider)) return fallback;

    final items = providerMultiKeyItemsFromProvider(provider);
    final available = items
        .where((item) =>
            item.enabled &&
            item.status != ProviderMultiKeyStatus.error &&
            item.key.trim().isNotEmpty)
        .toList();
    if (available.isNotEmpty) {
      return available.first.key.trim();
    }
    final enabled = items
        .where((item) => item.enabled && item.key.trim().isNotEmpty)
        .toList();
    if (enabled.isNotEmpty) {
      return enabled.first.key.trim();
    }
    return fallback;
  }

  Future<void> autoSaveProvider({
    required ProviderAuth provider,
    required String displayName,
    required String apiBaseUrl,
    required String apiPath,
    required String apiKey,
  }) {
    final customConfig = copyCustomConfigWithProviderChatApiPath(
      provider.customConfig,
      apiPath,
    );
    if (isProviderMultiKeyEnabled(provider)) {
      return _notifier.editProvider(
        providerId: provider.id,
        displayName: displayName,
        apiBaseUrl: apiBaseUrl,
        customConfig: customConfig,
      );
    }
    return _notifier.editProvider(
      providerId: provider.id,
      displayName: displayName,
      apiBaseUrl: apiBaseUrl,
      apiKeys: <String>[apiKey],
      customConfig: customConfig,
    );
  }

  Future<void> deleteProvider(String providerId) {
    return _notifier.deleteProvider(providerId);
  }

  Future<void> setProviderEnabled(ProviderAuth provider, bool enabled) {
    return _notifier.setProviderEnabled(provider.id, enabled);
  }

  Future<void> setProviderMultiKeyMode(
    ProviderAuth provider, {
    required bool enabled,
  }) {
    final items = providerMultiKeyItemsFromProvider(provider);
    final apiKeys = extractApiKeysFromProviderMultiKeyItems(items);
    final customConfig = buildProviderCustomConfigForMultiKey(
      provider: provider,
      enabled: enabled,
      strategy: providerMultiKeyStrategy(provider),
      items: items,
      roundRobinIndex:
          (provider.customConfig[providerMultiKeyRoundRobinIndexField] as num?)
              ?.toInt(),
    );
    return _notifier.editProvider(
      providerId: provider.id,
      apiKeys: apiKeys,
      customConfig: customConfig,
    );
  }

  Future<void> saveProviderMultiKeyItems({
    required ProviderAuth provider,
    required List<ProviderMultiKeyItem> items,
    bool? enabled,
    String? strategy,
    int? roundRobinIndex,
  }) {
    return _notifier.editProvider(
      providerId: provider.id,
      apiKeys: extractApiKeysFromProviderMultiKeyItems(items),
      customConfig: buildProviderCustomConfigForMultiKey(
        provider: provider,
        enabled: enabled,
        strategy: strategy,
        items: items,
        roundRobinIndex: roundRobinIndex,
      ),
    );
  }

  Future<void> updateRequestFormat(
    ProviderAuth provider,
    ProviderDetailRequestFormat format,
    String? apiPath,
  ) {
    var customConfig = Map<String, dynamic>.from(provider.customConfig);
    customConfig['requestFormat'] = format.value;
    customConfig = copyCustomConfigWithProviderChatApiPath(
      customConfig,
      apiPath,
    );
    return _notifier.editProvider(
      providerId: provider.id,
      customConfig: customConfig,
    );
  }

  Future<String> testModel({
    required ProviderAuth provider,
    required String apiKey,
    required String modelId,
  }) {
    return _notifier.testModel(
      providerId:
          resolveProviderDetailRequestFormat(provider, settings: _settings)
              .value,
      apiKey: apiKey,
      apiBaseUrl: provider.apiBaseUrl,
      modelId: modelId,
      customConfig: provider.customConfig,
    );
  }

  Future<void> reorderModels({
    required ProviderAuth provider,
    required List<String> modelIds,
  }) {
    return _notifier.reorderProviderModels(
      providerId: provider.id,
      modelIds: modelIds,
    );
  }

  Future<void> addCustomModel({
    required ProviderAuth provider,
    required String modelId,
    String? displayName,
  }) {
    return _notifier.addCustomModel(
      providerId: provider.id,
      modelId: modelId,
      displayName: displayName,
    );
  }
}
