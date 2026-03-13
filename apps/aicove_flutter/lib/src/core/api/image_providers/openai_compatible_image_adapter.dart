library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../providers/openai_adapter.dart';
import 'image_provider_adapter.dart';

class OpenAICompatibleImageAdapter implements ImageProviderAdapter {
  OpenAICompatibleImageAdapter({OpenAIAdapter? adapter})
      : _adapter = adapter ?? OpenAIAdapter();

  final OpenAIAdapter _adapter;

  @override
  String get name => 'openai';

  @override
  Future<ImageProviderResponse> generate({
    required http.Client client,
    required Duration timeout,
    required ImageProviderRequest request,
  }) async {
    final endpoint = _resolveEndpoint(
      baseUrl: request.baseUrl,
      customConfig: request.customConfig,
    );
    final payload = _buildPayload(request);

    final response = await client
        .post(
          Uri.parse(endpoint),
          headers: _adapter.buildHeaders(request.apiKey),
          body: jsonEncode(payload),
        )
        .timeout(timeout);

    final bodyString = utf8.decode(response.bodyBytes);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('HTTP ${response.statusCode}: $bodyString');
    }

    final data = jsonDecode(bodyString) as Map<String, dynamic>;
    final images = await _extractImages(
      client: client,
      timeout: timeout,
      data: data,
    );
    return ImageProviderResponse(images: images, rawResponse: data);
  }

  String _resolveEndpoint({
    required String baseUrl,
    Map<String, dynamic>? customConfig,
  }) {
    final customEndpoint =
        customConfig?['imageEndpoint']?.toString().trim() ?? '';
    if (customEndpoint.isNotEmpty) {
      final uri = Uri.tryParse(customEndpoint);
      if (uri != null && uri.hasScheme) {
        return customEndpoint;
      }
      final normalizedBase = baseUrl.replaceFirst(RegExp(r'/+$'), '');
      final path =
          customEndpoint.startsWith('/') ? customEndpoint : '/$customEndpoint';
      return '$normalizedBase$path';
    }
    return _adapter.buildEndpoint(baseUrl, modelType: 'image');
  }

  Map<String, dynamic> _buildPayload(ImageProviderRequest request) {
    final payload = <String, dynamic>{
      'model': request.model,
      'prompt': request.prompt,
      'n': request.count.clamp(1, 4),
      'size':
          '${request.width.clamp(256, 2048)}x${request.height.clamp(256, 2048)}',
      'response_format': _resolveResponseFormat(request.customConfig),
      if (request.negativePrompt != null &&
          request.negativePrompt!.trim().isNotEmpty)
        'negative_prompt': request.negativePrompt!.trim(),
    };

    final extra = request.customConfig?['image_parameters'];
    if (extra is Map) {
      payload.addAll(Map<String, dynamic>.from(extra));
    }
    return payload;
  }

  String _resolveResponseFormat(Map<String, dynamic>? customConfig) {
    final raw =
        customConfig?['imageResponseFormat']?.toString().trim().toLowerCase();
    if (raw == 'url') return 'url';
    if (raw == 'b64_json') return 'b64_json';
    return 'b64_json';
  }

  Future<List<Uint8List>> _extractImages({
    required http.Client client,
    required Duration timeout,
    required Map<String, dynamic> data,
  }) async {
    final results = <Uint8List>[];
    final items = (data['data'] as List?) ?? const <dynamic>[];

    for (final item in items) {
      if (item is! Map) continue;
      final image = Map<String, dynamic>.from(item);
      final b64 = image['b64_json']?.toString().trim() ?? '';
      if (b64.isNotEmpty) {
        results.add(base64Decode(b64));
        continue;
      }

      final url = image['url']?.toString().trim() ?? '';
      if (url.isEmpty) continue;
      results.add(await _downloadImage(
        client: client,
        timeout: timeout,
        url: url,
      ));
    }

    return results;
  }

  Future<Uint8List> _downloadImage({
    required http.Client client,
    required Duration timeout,
    required String url,
  }) async {
    final response = await client.get(Uri.parse(url)).timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('HTTP ${response.statusCode}: failed to download $url');
    }
    return response.bodyBytes;
  }
}
