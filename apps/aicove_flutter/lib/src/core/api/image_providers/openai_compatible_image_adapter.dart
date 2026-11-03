library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../media_request_retry.dart';
import '../providers/openai_adapter.dart';
import '../request_control.dart';
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
    final endpoint = resolveEndpoint(
      baseUrl: request.baseUrl,
      customConfig: request.customConfig,
      adapter: _adapter,
    );
    final payload = _buildPayload(request);

    final watch = Stopwatch()..start();
    final response = await sendMediaRequestWithRetry(
      send: () => client.send(
        RequestControl.request('POST', Uri.parse(endpoint))
          ..headers.addAll(_adapter.buildHeaders(request.apiKey))
          ..body = jsonEncode(payload),
      ),
      policy: MediaRetryPolicy.submission,
      remaining: () => timeout - watch.elapsed,
      phase: 'OpenAI image submission',
    );

    RequestControl.cancellation?.throwIfCancelled();
    final bodyBytes = response.bodyBytes;
    final statusCode = response.statusCode;
    final decoded = await _decodeOpenAiImageResponseInWorker(bodyBytes, statusCode);
    RequestControl.cancellation?.throwIfCancelled();
    final images = <Uint8List>[];
    for (final slot in decoded.slots) {
      RequestControl.cancellation?.throwIfCancelled();
      images.add(slot.bytes ?? await _downloadImage(client: client, timeout: timeout, url: slot.url!));
    }
    RequestControl.cancellation?.throwIfCancelled();
    return ImageProviderResponse(images: images, rawResponse: decoded.rawResponse);
  }

  static String resolveEndpoint({
    required String baseUrl,
    Map<String, dynamic>? customConfig,
    OpenAIAdapter? adapter,
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
    return (adapter ?? OpenAIAdapter()).buildEndpoint(baseUrl, modelType: 'image');
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

  Future<Uint8List> _downloadImage({
    required http.Client client,
    required Duration timeout,
    required String url,
  }) async {
    final watch = Stopwatch()..start();
    final response = await sendMediaRequestWithRetry(
      send: () => client.send(RequestControl.request('GET', Uri.parse(url))),
      policy: MediaRetryPolicy.readOnly,
      remaining: () => timeout - watch.elapsed,
      phase: 'OpenAI image download',
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('HTTP ${response.statusCode}: failed to download $url');
    }
    return response.bodyBytes;
  }
}

({Map<String, dynamic> rawResponse, List<({Uint8List? bytes, String? url})> slots})
_decodeOpenAiImageResponse(Uint8List bodyBytes, int statusCode) {
  final bodyString = utf8.decode(bodyBytes);
  if (statusCode < 200 || statusCode >= 300) {
    throw Exception('HTTP $statusCode: $bodyString');
  }
  final data = jsonDecode(bodyString) as Map<String, dynamic>;
  final slots = <({Uint8List? bytes, String? url})>[];
  for (final item in (data['data'] as List?) ?? const <dynamic>[]) {
    if (item is! Map) continue;
    final image = Map<String, dynamic>.from(item);
    final b64 = image['b64_json']?.toString().trim() ?? '';
    if (b64.isNotEmpty) {
      slots.add((bytes: base64Decode(b64), url: null));
    } else {
      final url = image['url']?.toString().trim() ?? '';
      if (url.isNotEmpty) slots.add((bytes: null, url: url));
    }
  }
  return (rawResponse: data, slots: slots);
}

Future<({Map<String, dynamic> rawResponse, List<({Uint8List? bytes, String? url})> slots})>
_decodeOpenAiImageResponseInWorker(Uint8List bytes, int statusCode) =>
    Isolate.run(() => _decodeOpenAiImageResponse(bytes, statusCode));
