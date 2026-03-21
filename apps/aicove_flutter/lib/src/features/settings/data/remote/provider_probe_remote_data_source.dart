import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../../core/api/providers/google_api_mode.dart';
import '../../../../core/api/providers/minimax_compat.dart';
import '../../../../core/api/providers/provider_adapter_factory.dart';
import '../../../../core/network/json_http_client.dart';
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
    if (_shouldUseMiniMaxFallbackModels(
      providerId: providerId,
      apiBaseUrl: apiBaseUrl,
      customConfig: customConfig,
    )) {
      return List<String>.from(kMiniMaxDefaultChatModels);
    }
    if (isNovelAiProvider(providerId: providerId, apiBaseUrl: apiBaseUrl)) {
      return kNovelAiDefaultModels;
    }
    if (isGoogleVertexExpressProvider(
      providerId: providerId,
      customConfig: customConfig,
    )) {
      return _previewVertexExpressProvider(
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
    try {
      final adapter = ProviderAdapterFactory.getAdapter(
        providerId,
        customConfig: customConfig,
        apiBaseUrl: apiBaseUrl,
      );
      final vertexExpress = isGoogleVertexExpressProvider(
        providerId: providerId,
        customConfig: customConfig,
      );
      final endpoint = adapter.name == 'gemini'
          ? buildGoogleGenerateContentEndpoint(
              baseUrl: apiBaseUrl,
              model: modelId,
              streaming: false,
              vertexExpress: vertexExpress,
            )
          : adapter.buildEndpoint(
              apiBaseUrl.replaceAll(RegExp(r'/+$'), ''),
              modelType: 'chat',
            );
      final headers = adapter.buildHeaders(apiKey);
      if (adapter.name == 'gemini' && vertexExpress) {
        headers.remove('x-goog-api-key');
      }
      final requestCustomConfig =
          ProviderAdapterFactory.sanitizeRequestCustomConfig(customConfig);
      final body = adapter.buildRequestBody(
        model: modelId,
        messages: [
          {'role': 'user', 'content': 'hi'},
        ],
        customConfig: {
          ...?requestCustomConfig,
          'max_tokens': 3,
        },
      );
      final uri = adapter.name == 'gemini'
          ? buildGoogleRequestUri(
              endpoint: endpoint,
              vertexExpress: vertexExpress,
              apiKey: apiKey,
            )
          : Uri.parse(endpoint);

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

  bool _shouldUseMiniMaxFallbackModels({
    required String providerId,
    required String apiBaseUrl,
    Map<String, dynamic>? customConfig,
  }) {
    if (!isMiniMaxApiUrl(apiBaseUrl)) return false;
    final resolved = ProviderAdapterFactory.resolveProvider(
      providerId,
      customConfig: customConfig,
      apiBaseUrl: apiBaseUrl,
    );
    return resolved == 'openai' ||
        resolved == 'claude' ||
        resolved == 'minimax';
  }

  Future<List<String>> _previewVertexExpressProvider({
    required String providerId,
    required String apiKey,
    required String apiBaseUrl,
    Map<String, dynamic>? customConfig,
  }) async {
    try {
      final models = <String>[];
      String? pageToken;

      do {
        final baseUri = buildGooglePublisherModelsListUri(
          baseUrl: apiBaseUrl,
          apiKey: apiKey,
        );
        final query = <String, String>{
          ...baseUri.queryParameters,
          'pageSize': '200',
          if (pageToken != null && pageToken.isNotEmpty) 'pageToken': pageToken,
        };
        final uri = baseUri.replace(queryParameters: query);
        final response = await JsonHttpClient.getJson(
          uri: uri,
          headers: const <String, String>{},
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
      throw Exception('Failed to fetch Vertex models: ${e.message}');
    } catch (e) {
      throw Exception('Failed to fetch Vertex models: $e');
    }
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
