import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../../core/api/providers/google_api_mode.dart';
import '../../../../core/api/providers/minimax_compat.dart';
import '../../../../core/api/providers/provider_chat_api_path.dart';
import '../../../../core/api/providers/provider_adapter_factory.dart';
import '../../../../core/api/providers/provider_extra_body.dart';
import '../../../../core/api/providers/zai_compat.dart';
import '../../../../core/network/json_http_client.dart';
import '../../../../core/api/image_providers/comfyui_workflow.dart';
import '../../../../core/api/image_providers/comfyui_image_adapter.dart';
import '../support/ui_models_store_support.dart';

/// 设置模块远端探测数据源。
/// 只负责模型列表预览和单模型连通性测试。
class ProviderProbeRemoteDataSource {
  const ProviderProbeRemoteDataSource({http.Client? httpClient})
    : _httpClient = httpClient;

  final http.Client? _httpClient;

  Future<List<String>> previewProvider({
    required String providerId,
    required String apiKey,
    required String apiBaseUrl,
    Map<String, dynamic>? customConfig,
  }) async {
    if (ComfyUIWorkflow.isProvider(providerId, customConfig)) {
      return const [ComfyUIWorkflow.modelId];
    }
    final resolvedProvider = ProviderAdapterFactory.resolveProvider(
      providerId,
      customConfig: customConfig,
      apiBaseUrl: apiBaseUrl,
    );
    if (isZaiProvider(providerId: providerId, apiBaseUrl: apiBaseUrl)) {
      return _previewZaiProvider(
        providerId: providerId,
        apiKey: apiKey,
        apiBaseUrl: apiBaseUrl,
        customConfig: customConfig,
      );
    }
    if (isMiniMaxApiUrl(apiBaseUrl)) {
      return _previewMiniMaxProvider(
        providerId: providerId,
        apiKey: apiKey,
        apiBaseUrl: apiBaseUrl,
        customConfig: customConfig,
      );
    }
    if (isNovelAiProvider(providerId: providerId, apiBaseUrl: apiBaseUrl)) {
      return kNovelAiDefaultModels;
    }
    if (resolvedProvider == 'gemini') {
      return _previewGeminiProvider(
        providerId: providerId,
        apiKey: apiKey,
        apiBaseUrl: apiBaseUrl,
        customConfig: customConfig,
      );
    }

    try {
      final adapter = ProviderAdapterFactory.getAdapter(
        providerId,
        customConfig: customConfig,
        apiBaseUrl: apiBaseUrl,
      );
      final base = apiBaseUrl.replaceAll(RegExp(r'/+$'), '');
      final uri = Uri.parse('$base/models');
      final response = await JsonHttpClient.getJson(
        uri: uri,
        headers: adapter.buildHeaders(apiKey),
        timeout: const Duration(seconds: 10),
        client: _httpClient,
      );
      final models = _extractPreviewModels(
        response.data,
        providerId: providerId,
        customConfig: customConfig,
      );

      if (models.isEmpty) {
        throw Exception('No models found');
      }

      return models;
    } on JsonHttpRequestException catch (e) {
      throw Exception('Failed to fetch models: ${e.message}');
    } catch (e) {
      throw Exception('Failed to fetch models: $e');
    }
  }

  Future<String> testModel({
    required String providerId,
    required String apiKey,
    required String apiBaseUrl,
    required String modelId,
    Map<String, dynamic>? customConfig,
  }) async {
    if (ComfyUIWorkflow.isProvider(providerId, customConfig)) {
      final client = _httpClient ?? http.Client();
      try {
        final response = await client
            .get(
              ComfyUIImageAdapter.endpoint(apiBaseUrl, 'system_stats'),
              headers: ComfyUIImageAdapter.headers(apiKey),
            )
            .timeout(const Duration(seconds: 15));
        if (response.statusCode != 200 ||
            (jsonDecode(response.body) as Map)['system'] == null) {
          throw StateError('ComfyUI 连接失败：HTTP ${response.statusCode}');
        }
        return 'ComfyUI 连接成功（未执行生图）';
      } finally {
        if (_httpClient == null) client.close();
      }
    }
    try {
      final adapter = ProviderAdapterFactory.getAdapter(
        providerId,
        customConfig: customConfig,
        apiBaseUrl: apiBaseUrl,
      );
      final endpoint = buildProviderChatEndpoint(
        provider: adapter.name,
        apiBaseUrl: apiBaseUrl,
        model: modelId,
        customConfig: customConfig,
      );
      final requestCustomConfig =
          ProviderAdapterFactory.sanitizeRequestCustomConfig(customConfig);
      final body = adapter.buildRequestBody(
        model: modelId,
        messages: [
          {'role': 'user', 'content': 'hi'},
        ],
        customConfig: {...?requestCustomConfig, 'max_tokens': 3},
      );
      applyProviderExtraBody(body, customConfig);
      final uri = adapter.name == 'gemini'
          ? buildGoogleRequestUri(
              endpoint: endpoint,
              vertexExpress: isGoogleAiPlatformPublisherBaseUrl(apiBaseUrl),
              apiKey: apiKey,
            )
          : Uri.parse(endpoint);
      final headers = adapter.name == 'gemini'
          ? _buildGeminiHeaders(
              adapter: adapter,
              apiBaseUrl: apiBaseUrl,
              apiKey: apiKey,
            )
          : adapter.buildHeaders(apiKey);

      final response = await _post(
        uri,
        headers: headers,
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        final msg = response.body.length > 200
            ? response.body.substring(0, 200)
            : response.body;
        throw Exception('HTTP ${response.statusCode}: $msg');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final result = adapter.parseResponse(data);
      return result.text.isNotEmpty ? result.text : '(模型响应成功，无文本内容)';
    } catch (e) {
      throw Exception('模型测试失败: $e');
    }
  }

  Future<List<String>> _previewGeminiProvider({
    required String providerId,
    required String apiKey,
    required String apiBaseUrl,
    Map<String, dynamic>? customConfig,
  }) async {
    try {
      final adapter = ProviderAdapterFactory.getAdapter(
        providerId,
        customConfig: customConfig,
        apiBaseUrl: apiBaseUrl,
      );
      final base =
          (apiBaseUrl.trim().isEmpty
                  ? kGeminiDeveloperApiBase
                  : apiBaseUrl.trim())
              .replaceAll(RegExp(r'/+$'), '');
      final models = <String>[];
      String? pageToken;

      do {
        final query = <String, String>{
          'pageSize': '200',
          if (pageToken != null && pageToken.isNotEmpty) 'pageToken': pageToken,
        };
        final uri =
            buildGooglePublisherModelsListUri(
              baseUrl: base,
              apiKey: apiKey,
            ).replace(
              queryParameters: <String, String>{
                ...buildGooglePublisherModelsListUri(
                  baseUrl: base,
                  apiKey: apiKey,
                ).queryParameters,
                ...query,
              },
            );
        final response = await JsonHttpClient.getJson(
          uri: uri,
          headers: _buildGeminiHeaders(
            adapter: adapter,
            apiBaseUrl: apiBaseUrl,
            apiKey: apiKey,
          ),
          timeout: const Duration(seconds: 10),
          client: _httpClient,
        );
        final pageModels = _extractPreviewModels(
          response.data,
          providerId: providerId,
          customConfig: customConfig,
        );
        for (final model in pageModels) {
          if (!models.contains(model)) {
            models.add(model);
          }
        }
        final nextToken = response.data['nextPageToken']?.toString().trim();
        pageToken = (nextToken == null || nextToken.isEmpty) ? null : nextToken;
      } while (pageToken != null);

      if (models.isEmpty) {
        throw Exception('No models found');
      }

      return models;
    } on JsonHttpRequestException catch (e) {
      throw Exception('Failed to fetch Gemini models: ${e.message}');
    } catch (e) {
      throw Exception('Failed to fetch Gemini models: $e');
    }
  }

  Map<String, String> _buildGeminiHeaders({
    required dynamic adapter,
    required String apiBaseUrl,
    required String apiKey,
  }) {
    final headers = Map<String, String>.from(adapter.buildHeaders(apiKey));
    if (isGoogleAiPlatformPublisherBaseUrl(apiBaseUrl)) {
      headers.remove('x-goog-api-key');
    }
    return headers;
  }

  Future<List<String>> _previewMiniMaxProvider({
    required String providerId,
    required String apiKey,
    required String apiBaseUrl,
    Map<String, dynamic>? customConfig,
  }) async {
    final fallbackModels = List<String>.from(kMiniMaxDefaultPreviewModels);
    final modelsEndpoint = buildMiniMaxModelsEndpoint(apiBaseUrl);
    if (modelsEndpoint == null) {
      return fallbackModels;
    }

    try {
      final response = await JsonHttpClient.getJson(
        uri: Uri.parse(modelsEndpoint),
        headers: ProviderAdapterFactory.getAdapter(
          'openai',
        ).buildHeaders(apiKey),
        timeout: const Duration(seconds: 10),
        client: _httpClient,
      );
      final models = _extractPreviewModels(
        response.data,
        providerId: providerId,
        customConfig: customConfig,
      );
      if (models.isNotEmpty) {
        return mergeMiniMaxPreviewModels(models);
      }
    } catch (_) {
      // MiniMax 官方未文档化稳定的模型列表接口，失败时回退到文档兜底模型。
    }

    return fallbackModels;
  }

  Future<List<String>> _previewZaiProvider({
    required String providerId,
    required String apiKey,
    required String apiBaseUrl,
    Map<String, dynamic>? customConfig,
  }) async {
    final fallbackModels = List<String>.from(kZaiDefaultChatModels);

    try {
      final adapter = ProviderAdapterFactory.getAdapter(
        providerId,
        customConfig: customConfig,
        apiBaseUrl: apiBaseUrl,
      );
      final modelsEndpoint =
          '${apiBaseUrl.replaceAll(RegExp(r'/+$'), '')}/models';
      final response = await JsonHttpClient.getJson(
        uri: Uri.parse(modelsEndpoint),
        headers: adapter.buildHeaders(apiKey),
        timeout: const Duration(seconds: 10),
        client: _httpClient,
      );
      final models = _extractPreviewModels(
        response.data,
        providerId: providerId,
        customConfig: customConfig,
      );
      if (models.isNotEmpty) {
        return models;
      }
    } catch (_) {
      // Z.AI 当前公开文档未列出稳定的 /models 接口，失败时回退到内置列表。
    }

    return fallbackModels;
  }

  List<String> _extractPreviewModels(
    Map<String, dynamic> data, {
    required String providerId,
    Map<String, dynamic>? customConfig,
  }) {
    final normalizedProvider = providerId.trim().toLowerCase();
    final models = <String>[];

    void addModel(String rawModelId) {
      final raw = rawModelId.trim();
      if (raw.isEmpty) return;
      final normalized = _normalizePreviewModelId(
        raw,
        providerId: normalizedProvider,
        customConfig: customConfig,
      );
      if (normalized.isEmpty || models.contains(normalized)) {
        return;
      }
      models.add(normalized);
    }

    final dataList = data['data'];
    if (dataList is List) {
      for (final item in dataList) {
        if (item is! Map) continue;
        addModel(item['id']?.toString() ?? '');
      }
    }

    final geminiModels = data['models'];
    if (geminiModels is List) {
      for (final item in geminiModels) {
        if (item is! Map) continue;
        addModel(item['name']?.toString() ?? '');
      }
    }

    final publisherModels = data['publisherModels'];
    if (publisherModels is List) {
      for (final item in publisherModels) {
        if (item is! Map) continue;
        addModel(item['name']?.toString() ?? '');
      }
    }

    return models;
  }

  String _normalizePreviewModelId(
    String modelId, {
    required String providerId,
    Map<String, dynamic>? customConfig,
  }) {
    final normalized = modelId.trim();
    if (normalized.isEmpty) return '';

    if (ProviderAdapterFactory.resolveProvider(
          providerId,
          customConfig: customConfig,
        ) ==
        'gemini') {
      return normalizeGoogleModelId(
        normalized,
        vertexExpress: isGoogleVertexExpressProvider(
          providerId: providerId,
          customConfig: customConfig,
        ),
      );
    }

    return normalized;
  }

  Future<http.Response> _post(
    Uri uri, {
    required Map<String, String> headers,
    required String body,
  }) {
    final client = _httpClient;
    if (client != null) {
      return client.post(uri, headers: headers, body: body);
    }
    return http.post(uri, headers: headers, body: body);
  }
}
