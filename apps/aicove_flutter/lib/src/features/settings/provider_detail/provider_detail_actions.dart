import '../../voice_call/data/cloud_asr/asr_model_probe.dart';
import '../../voice_call/domain/asr_request_format.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/providers/provider_chat_api_path.dart';
import '../../../core/api/providers/provider_extra_body.dart';
import '../../plugins/tts/tts_model_probe.dart';
import '../../plugins/tts/tts_request_format.dart';
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
    final fallback = provider.apiKeys.isNotEmpty
        ? provider.apiKeys.first.trim()
        : '';
    if (!isProviderMultiKeyEnabled(provider)) return fallback;

    final items = providerMultiKeyItemsFromProvider(provider);
    final available = items
        .where(
          (item) =>
              item.enabled &&
              item.status != ProviderMultiKeyStatus.error &&
              item.key.trim().isNotEmpty,
        )
        .toList();
    if (providerMultiKeyStrategy(provider) == providerMultiKeyStrategyExhaust &&
        available.isNotEmpty) {
      final currentIndex =
          (provider.customConfig[providerMultiKeyRoundRobinIndexField] as num?)
              ?.toInt() ??
          0;
      final normalizedIndex = currentIndex.clamp(0, items.length - 1).toInt();
      for (var offset = 0; offset < items.length; offset++) {
        final index = (normalizedIndex + offset) % items.length;
        final item = items[index];
        if (item.enabled &&
            item.status != ProviderMultiKeyStatus.error &&
            item.key.trim().isNotEmpty) {
          return item.key.trim();
        }
      }
    }
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
    if (format.value == TtsRequestFormat.customRest.value) {
      customConfig.putIfAbsent(
        TtsRequestFormat.customRestTemplateKey,
        () =>
            Map<String, dynamic>.of(TtsRequestFormat.defaultCustomRestTemplate),
      );
    }
    customConfig = copyCustomConfigWithProviderChatApiPath(
      customConfig,
      apiPath,
    );
    return _notifier.editProvider(
      providerId: provider.id,
      customConfig: customConfig,
    );
  }

  /// 合并若干 customConfig 键；值为 null 的键删除。
  Future<void> saveCustomConfigValues(
    ProviderAuth provider,
    Map<String, String?> values,
  ) {
    final latest =
        _settings?.providers
            .where((item) => item.id == provider.id)
            .firstOrNull ??
        provider;
    final next = Map<String, dynamic>.of(latest.customConfig);
    values.forEach((key, value) {
      if (value == null) {
        next.remove(key);
      } else {
        next[key] = value;
      }
    });
    return _notifier.editProvider(providerId: provider.id, customConfig: next);
  }

  Future<void> saveTtsRequestTemplate(
    ProviderAuth provider,
    Map<String, dynamic> template,
  ) {
    final latest =
        _settings?.providers
            .where((item) => item.id == provider.id)
            .firstOrNull ??
        provider;
    return _notifier.editProvider(
      providerId: provider.id,
      customConfig: {
        ...latest.customConfig,
        TtsRequestFormat.customRestTemplateKey: template,
      },
    );
  }

  Future<void> saveExtraBody(
    ProviderAuth provider,
    Map<String, dynamic> extraBody,
  ) {
    final latest =
        _settings?.providers
            .where((item) => item.id == provider.id)
            .firstOrNull ??
        provider;
    return _notifier.editProvider(
      providerId: provider.id,
      customConfig: copyCustomConfigWithProviderExtraBody(
        latest.customConfig,
        extraBody,
      ),
    );
  }

  Future<String> testModel({
    required ProviderAuth provider,
    required String apiKey,
    required String modelId,
  }) {
    final settings = _settings;
    final modelType =
        settings?.getModelType(settings.buildModelRef(provider.id, modelId)) ??
        ModelType.inferFromModelId(modelId);
    switch (modelType) {
      case ModelType.stt:
        if (AsrRequestFormat.ofConfig(provider.customConfig) == null) {
          throw UnsupportedError('渠道没有设置语音识别格式');
        }
        return AsrModelProbe.run(
          provider: provider,
          apiKey: apiKey,
          modelId: modelId,
        );
      case ModelType.embedding:
        throw UnsupportedError('暂不支持测试${modelType.label}模型');
      case ModelType.tts:
        if (settings == null) throw StateError('设置尚未加载');
        return TtsModelProbe.run(
          settings: settings,
          provider: provider,
          apiKey: apiKey,
          modelId: modelId,
        );
      case ModelType.chat:
      case ModelType.image:
        return _notifier.testModel(
          providerId: resolveProviderDetailRequestFormat(
            provider,
            settings: settings,
          ).value,
          apiKey: apiKey,
          apiBaseUrl: provider.apiBaseUrl,
          modelId: modelId,
          customConfig: provider.customConfig,
          modelType: modelType,
        );
    }
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
