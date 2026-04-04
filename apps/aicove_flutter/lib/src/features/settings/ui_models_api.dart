import 'package:http/http.dart' as http;

import '../../core/api/providers/google_api_mode.dart';
import '../../core/api/providers/minimax_compat.dart';
import '../../core/api/providers/provider_adapter_factory.dart';
import '../../core/api/providers/zai_compat.dart';
import 'data/local/ui_models_store_local_data_source.dart';
import 'data/remote/provider_probe_remote_data_source.dart';
import 'data/support/ui_models_store_support.dart';

/// 设置模块数据门面。
/// 对外保持原有 API，不直接承载具体存储和网络细节。
class UiModelsApi {
  UiModelsApi({http.Client? httpClient})
      : _remote = ProviderProbeRemoteDataSource(httpClient: httpClient);

  final UiModelsStoreLocalDataSource _local =
      const UiModelsStoreLocalDataSource();
  final ProviderProbeRemoteDataSource _remote;

  Future<Map<String, dynamic>> fetchAll() {
    return _local.fetchAll();
  }

  Future<Map<String, dynamic>> updatePartial(
    Map<String, dynamic> partial, {
    String? bearerToken,
  }) {
    return _local.updatePartial(partial);
  }

  Future<List<String>> previewProvider({
    required String providerId,
    required String apiKey,
    required String apiBaseUrl,
    Map<String, dynamic>? customConfig,
  }) {
    return _remote.previewProvider(
      providerId: providerId,
      apiKey: apiKey,
      apiBaseUrl: apiBaseUrl,
      customConfig: customConfig,
    );
  }

  Future<String> testModel({
    required String providerId,
    required String apiKey,
    required String apiBaseUrl,
    required String modelId,
    Map<String, dynamic>? customConfig,
  }) {
    return _remote.testModel(
      providerId: providerId,
      apiKey: apiKey,
      apiBaseUrl: apiBaseUrl,
      modelId: modelId,
      customConfig: customConfig,
    );
  }

  Future<Map<String, dynamic>> importProvider({
    required String providerId,
    String? model,
    required String apiKey,
    required String apiBaseUrl,
    String? displayName,
    List<String>? visibleModels,
    List<String>? hiddenModels,
    List<String>? allModels,
    List<String>? capabilities,
    Map<String, dynamic>? customConfig,
  }) async {
    if (providerId != 'openai_full_compat' && apiKey.trim().isEmpty) {
      throw ArgumentError('provider_id 和 api_key 不能为空');
    }

    final requestFormat =
        customConfig?['requestFormat']?.toString().trim().toLowerCase();
    final isNovelAi =
        isNovelAiProvider(providerId: providerId, apiBaseUrl: apiBaseUrl) ||
            requestFormat == 'novelai' ||
            requestFormat == 'nai';
    final isGemini = ProviderAdapterFactory.resolveProvider(
          providerId,
          customConfig: customConfig,
          apiBaseUrl: apiBaseUrl,
        ) ==
        'gemini';
    final isMiniMax = isMiniMaxApiUrl(apiBaseUrl);
    final isZai = isZaiProvider(
      providerId: providerId,
      apiBaseUrl: apiBaseUrl,
    );

    List<String> models;
    if (allModels != null) {
      models = cleanSettingsStrings(allModels);
      if (isMiniMax && models.isEmpty) {
        models = List<String>.from(kMiniMaxDefaultChatModels);
      } else if (isZai && models.isEmpty) {
        models = List<String>.from(kZaiDefaultChatModels);
      }
    } else {
      try {
        models = await previewProvider(
          providerId: providerId,
          apiKey: apiKey,
          apiBaseUrl: apiBaseUrl,
          customConfig: customConfig,
        );
      } catch (e) {
        if (isNovelAi) {
          models = List<String>.from(kNovelAiDefaultModels);
        } else if (isGemini) {
          models = const <String>[];
        } else if (isMiniMax) {
          models = List<String>.from(kMiniMaxDefaultChatModels);
        } else if (isZai) {
          models = List<String>.from(kZaiDefaultChatModels);
        } else {
          rethrow;
        }
      }
    }

    if (model != null &&
        model.trim().isNotEmpty &&
        !models.contains(model.trim())) {
      models.insert(0, model.trim());
    }
    if (isNovelAi) {
      models = normalizeNovelAiModels(models);
    }

    return _local.importProvider(
      providerId: providerId,
      model: model,
      apiKey: apiKey,
      apiBaseUrl: apiBaseUrl,
      displayName: displayName,
      visibleModels: visibleModels,
      hiddenModels: hiddenModels,
      capabilities: capabilities,
      customConfig: customConfig,
      models: models,
    );
  }

  Future<Map<String, dynamic>> updateProvider({
    required String providerId,
    String? displayName,
    String? apiBaseUrl,
    List<String>? apiKeys,
    bool? enabled,
    List<String>? capabilities,
    Map<String, dynamic>? customConfig,
    List<String>? allModels,
    List<String>? visibleModels,
    List<String>? hiddenModels,
    bool? disableToolCalling,
    double? temperature,
    bool clearTemperature = false,
    double? topP,
    bool clearTopP = false,
    int? contextMessageLimit,
    bool clearContextMessageLimit = false,
    int? maxContextTokens,
    bool clearMaxContextTokens = false,
  }) {
    return _local.updateProvider(
      providerId: providerId,
      displayName: displayName,
      apiBaseUrl: apiBaseUrl,
      apiKeys: apiKeys,
      enabled: enabled,
      capabilities: capabilities,
      customConfig: customConfig,
      allModels: allModels,
      visibleModels: visibleModels,
      hiddenModels: hiddenModels,
      disableToolCalling: disableToolCalling,
      temperature: temperature,
      clearTemperature: clearTemperature,
      topP: topP,
      clearTopP: clearTopP,
      contextMessageLimit: contextMessageLimit,
      clearContextMessageLimit: clearContextMessageLimit,
      maxContextTokens: maxContextTokens,
      clearMaxContextTokens: clearMaxContextTokens,
    );
  }

  Future<Map<String, dynamic>> deleteProvider(String providerId) {
    return _local.deleteProvider(providerId);
  }

  Future<Map<String, dynamic>> reorderProviders(List<String> providerIds) {
    return _local.reorderProviders(providerIds);
  }

  Future<Map<String, dynamic>> reorderProviderModels({
    required String providerId,
    required List<String> modelIds,
  }) {
    return _local.reorderProviderModels(
      providerId: providerId,
      modelIds: modelIds,
    );
  }
}
