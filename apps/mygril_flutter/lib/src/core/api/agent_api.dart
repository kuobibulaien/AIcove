import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import '../config.dart';
import '../api_logger.dart';
import '../app_logger.dart';
import 'providers/provider_adapter_factory.dart';
import 'providers/provider_adapter.dart' show ToolCall;

class SendMessageRichResult {
  final String text;
  final List<Map<String, dynamic>> toolResults;
  final List<ToolCall> toolCalls; // AI 璇锋眰鎵ц鐨勫伐鍏疯皟鐢?
  final Map<String, dynamic>? rawResponse; // 鍘熷鍝嶅簲锛堢敤浜庝袱鍥炲悎宸ュ叿璋冪敤锛?

  const SendMessageRichResult({
    required this.text,
    required this.toolResults,
    this.toolCalls = const [],
    this.rawResponse,
  });

  /// 鏄惁鏈夊緟鎵ц鐨勫伐鍏疯皟鐢?
  bool get hasToolCalls => toolCalls.isNotEmpty;

  String? firstTtsUrl() {
    for (final item in toolResults) {
      final name = (item['name'] ?? '').toString();
      final payload = (item['payload'] as Map<String, dynamic>?) ??
          const <String, dynamic>{};
      if (name == 'tts') {
        final url = payload['audio_url']?.toString();
        if (url != null && url.isNotEmpty) return url;
      }
    }
    return null;
  }
}

class ImageGenerationResult {
  final List<Uint8List> images;
  final String provider;
  final String model;
  final Map<String, dynamic>? rawResponse;

  const ImageGenerationResult({
    required this.images,
    required this.provider,
    required this.model,
    this.rawResponse,
  });

  bool get isEmpty => images.isEmpty;
}

class AgentApiClient {
  static const _novelAiDefaultBase = 'https://image.novelai.net';
  static const _novelAiLegacyBase = 'https://api.novelai.net';
  static const _novelAiDefaultModel = 'nai-diffusion-4-5-curated';
  static const Map<String, String> _novelAiModelAliases = {
    // Backward compatibility for older local presets.
    'nai-diffusion-4-5-curated-preview': 'nai-diffusion-4-5-curated',
  };
  static const List<String> _novelAiModelFallbackOrder = <String>[
    'nai-diffusion-4-5-curated',
    'nai-diffusion-4-5-full',
    'nai-diffusion-3',
  ];

  final http.Client _client;
  final Duration timeout;

  AgentApiClient({http.Client? client, Duration? timeout})
      : _client = client ?? http.Client(),
        timeout = timeout ?? const Duration(seconds: 30);

  // 浜嬩欢鏃ュ織锛堟枃鏈椋庢牸锛涗笉寮曞叆鏂颁緷璧栵級
  void _evt(String name, Map<String, Object?> data, {String level = 'INFO'}) {
    final now = DateTime.now();
    final ts =
        '[${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}]';
    const source = 'AgentApiClient';
    final parts = <String>[];
    data.forEach((k, v) {
      if (v == null) return;
      final val =
          v is String && v.length > 120 ? '${v.substring(0, 120)}...' : v;
      parts.add('$k=$val');
    });
    final kv = parts.isEmpty ? '' : ' ${parts.join(' ')}';
    // ignore: avoid_print
    print('$ts [Core] [$level] [$source:$name]::$kv');
  }

  Uri _uri(String path) {
    final base = resolvedApiBase();
    final p = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$base$p');
  }

  Future<Map<String, dynamic>> _postJson(String path, Map<String, dynamic> body,
      {Map<String, String>? headers}) async {
    final uri = _uri(path);
    final payload = jsonEncode(body);
    final sw = Stopwatch()..start();
    final res = await _client
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            ...?headers,
          },
          body: payload,
        )
        .timeout(timeout);
    sw.stop();
    ApiLogger.add(ApiLogEntry(
      time: DateTime.now(),
      method: 'POST',
      url: uri.toString(),
      status: res.statusCode,
      durationMs: sw.elapsedMilliseconds,
      requestBody: ApiLogger.safeSnippet(payload),
      responseBody: ApiLogger.safeSnippet(utf8.decode(res.bodyBytes)),
      ok: res.statusCode >= 200 && res.statusCode < 300,
    ));
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    }
    throw Exception('HTTP ${res.statusCode}: ${res.body}');
  }

  Future<Map<String, dynamic>> getModels({String? token}) async {
    final uri = _uri('/v1/models');
    final headers = <String, String>{};
    if (token != null && token.trim().isNotEmpty) {
      headers['Authorization'] = 'Bearer ${token.trim()}';
    }
    final res = await _client.get(uri, headers: headers).timeout(timeout);
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    }
    throw Exception('HTTP ${res.statusCode}: ${res.body}');
  }

  Future<ImageGenerationResult> generateImage({
    required String provider,
    required String model,
    required String prompt,
    String? negativePrompt,
    int width = 1024,
    int height = 1024,
    int count = 1,
    int? steps,
    double? guidanceScale,
    int? seed,
    String? sampler,
    String? providerApiBase,
    String? providerApiKey,
    Map<String, dynamic>? customConfig,
  }) async {
    final normalizedProvider = provider.toLowerCase().trim();
    final trimmedBase = providerApiBase?.trim();
    final trimmedKey = providerApiKey?.trim();
    if (trimmedKey == null || trimmedKey.isEmpty) {
      throw StateError('Missing providerApiKey for image generation');
    }
    final isNovelAi =
        normalizedProvider == 'novelai' || normalizedProvider == 'nai';
    if (isNovelAi) {
      final base = _normalizeNovelAiBaseUrl(trimmedBase);
      final normalizedNovelAiModel = _normalizeNovelAiModel(
        model,
        customConfig: customConfig,
      );
      final candidates = _buildNovelAiModelCandidates(normalizedNovelAiModel);
      Object? lastError;
      for (final candidate in candidates) {
        try {
          return await _generateImageWithNovelAI(
            provider: normalizedProvider,
            model: candidate,
            prompt: prompt,
            negativePrompt: negativePrompt,
            width: width,
            height: height,
            count: count,
            steps: steps,
            guidanceScale: guidanceScale,
            seed: seed,
            sampler: sampler,
            baseUrl: base,
            apiKey: trimmedKey,
            customConfig: customConfig,
          );
        } catch (e) {
          lastError = e;
          if (!_isNovelAiModelEnumError(e) || candidate == candidates.last) {
            rethrow;
          }
          _evt(
              'image:novelai_model_retry',
              {
                'reason': 'enum_error',
                'from': candidate,
                'to': candidates[candidates.indexOf(candidate) + 1],
                'baseUrl': base,
              },
              level: 'WARN');
        }
      }
      if (lastError != null) throw lastError;
    }
    final base = (trimmedBase == null || trimmedBase.isEmpty)
        ? 'https://api.openai.com/v1'
        : trimmedBase;
    return _generateImageWithOpenAICompatible(
      provider: normalizedProvider,
      model: model,
      prompt: prompt,
      negativePrompt: negativePrompt,
      width: width,
      height: height,
      count: count,
      baseUrl: base,
      apiKey: trimmedKey,
      customConfig: customConfig,
    );
  }

  String _normalizeNovelAiModel(
    String model, {
    Map<String, dynamic>? customConfig,
  }) {
    final explicit = model.trim();
    final fromConfig =
        customConfig?['defaultImageModel']?.toString().trim() ?? '';
    final candidate = explicit.isNotEmpty ? explicit : fromConfig;
    if (candidate.isEmpty) return _novelAiDefaultModel;
    return _novelAiModelAliases[candidate] ?? candidate;
  }

  String _normalizeNovelAiBaseUrl(String? baseUrl) {
    final trimmed = baseUrl?.trim() ?? '';
    if (trimmed.isEmpty) return _novelAiDefaultBase;
    final lowered = trimmed.toLowerCase();
    if (lowered.startsWith(_novelAiLegacyBase)) {
      return _novelAiDefaultBase + trimmed.substring(_novelAiLegacyBase.length);
    }
    try {
      final uri = Uri.parse(trimmed);
      if (uri.host.toLowerCase() == 'api.novelai.net') {
        return uri.replace(host: 'image.novelai.net').toString();
      }
    } catch (_) {}
    return trimmed;
  }

  List<String> _buildNovelAiModelCandidates(String primary) {
    final normalizedPrimary = _novelAiModelAliases[primary] ?? primary;
    final candidates = <String>[];
    void add(String modelId) {
      final fixed = (_novelAiModelAliases[modelId] ?? modelId).trim();
      if (fixed.isEmpty || candidates.contains(fixed)) return;
      candidates.add(fixed);
    }

    add(normalizedPrimary);
    for (final fallback in _novelAiModelFallbackOrder) {
      add(fallback);
    }
    if (candidates.isEmpty) {
      return const <String>[_novelAiDefaultModel];
    }
    return candidates;
  }

  bool _isNovelAiModelEnumError(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('model must be a valid enum value');
  }

  Future<ImageGenerationResult> _generateImageWithOpenAICompatible({
    required String provider,
    required String model,
    required String prompt,
    required int width,
    required int height,
    required int count,
    required String baseUrl,
    required String apiKey,
    String? negativePrompt,
    Map<String, dynamic>? customConfig,
  }) async {
    final adapter = ProviderAdapterFactory.getAdapter(provider);
    final endpoint = adapter.buildEndpoint(baseUrl, modelType: 'image');
    final payload = <String, dynamic>{
      'model': model,
      'prompt': prompt,
      'n': count.clamp(1, 4),
      'size': '${width.clamp(256, 2048)}x${height.clamp(256, 2048)}',
      // Force base64 to avoid optional external URL download hop.
      'response_format': 'b64_json',
      if (negativePrompt != null && negativePrompt.trim().isNotEmpty)
        'negative_prompt': negativePrompt.trim(),
      ...?customConfig,
    };
    final headers = adapter.buildHeaders(apiKey);
    final resp = await _client
        .post(
          Uri.parse(endpoint),
          headers: headers,
          body: jsonEncode(payload),
        )
        .timeout(timeout);
    final bodyString = utf8.decode(resp.bodyBytes);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('HTTP ${resp.statusCode}: $bodyString');
    }
    final data = jsonDecode(bodyString) as Map<String, dynamic>;
    final images = <Uint8List>[];
    final items = (data['data'] as List?) ?? const [];
    for (final item in items) {
      if (item is! Map<String, dynamic>) continue;
      final b64 = item['b64_json']?.toString();
      if (b64 != null && b64.isNotEmpty) {
        images.add(base64Decode(b64));
      }
    }
    return ImageGenerationResult(
      images: images,
      provider: provider,
      model: model,
      rawResponse: data,
    );
  }

  Future<ImageGenerationResult> _generateImageWithNovelAI({
    required String provider,
    required String model,
    required String prompt,
    required int width,
    required int height,
    required int count,
    required String baseUrl,
    required String apiKey,
    String? negativePrompt,
    int? steps,
    double? guidanceScale,
    int? seed,
    String? sampler,
    Map<String, dynamic>? customConfig,
  }) async {
    final normalized = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final endpoint = '$normalized/ai/generate-image';
    final samplerValue = sampler?.trim();
    final negativePromptValue = negativePrompt?.trim();
    final params = <String, dynamic>{
      'params_version': 3,
      'width': width.clamp(256, 2048),
      'height': height.clamp(256, 2048),
      'n_samples': count.clamp(1, 4),
      'steps': (steps ?? 23).clamp(1, 50),
      'scale': guidanceScale ?? 5.0,
      'sampler': (samplerValue != null && samplerValue.isNotEmpty)
          ? samplerValue
          : 'k_euler_ancestral',
      'qualityToggle': true,
      'legacy': false,
      'noise_schedule': 'karras',
      'add_original_image': true,
      if (seed != null) 'seed': seed,
      if (negativePromptValue != null && negativePromptValue.isNotEmpty)
        'negative_prompt': negativePromptValue,
      if (negativePromptValue != null && negativePromptValue.isNotEmpty)
        'uc': negativePromptValue,
    };
    if (_isNovelAiV4Model(model)) {
      final v4Negative =
          (negativePromptValue == null || negativePromptValue.isEmpty)
              ? 'lowres'
              : negativePromptValue;
      params.addAll(<String, dynamic>{
        'use_coords': false,
        'legacy_uc': false,
        'characterPrompts': const <dynamic>[],
        'v4_prompt': <String, dynamic>{
          'caption': <String, dynamic>{
            'base_caption': prompt,
            'char_captions': const <dynamic>[],
          },
          'use_coords': false,
          'use_order': true,
        },
        'v4_negative_prompt': <String, dynamic>{
          'caption': <String, dynamic>{
            'base_caption': v4Negative,
            'char_captions': const <dynamic>[],
          },
          'legacy_uc': false,
        },
      });
    }
    final configParams = customConfig?['image_parameters'];
    if (configParams is Map<String, dynamic>) {
      params.addAll(configParams);
    }
    final payload = <String, dynamic>{
      'input': prompt,
      'model': model,
      'action': 'generate',
      'parameters': params,
    };
    final resp = await _client
        .post(
          Uri.parse(endpoint),
          headers: <String, String>{
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
            'Accept': 'application/zip',
          },
          body: jsonEncode(payload),
        )
        .timeout(timeout);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception(
          'HTTP ${resp.statusCode}: ${utf8.decode(resp.bodyBytes)}');
    }
    final bytes = resp.bodyBytes;
    final images = _extractImageBytesFromNovelAIResponse(bytes, resp.headers);
    return ImageGenerationResult(
      images: images,
      provider: provider,
      model: model,
    );
  }

  bool _isNovelAiV4Model(String model) {
    final value = model.toLowerCase().trim();
    return value.startsWith('nai-diffusion-4');
  }

  List<Uint8List> _extractImageBytesFromNovelAIResponse(
    Uint8List bytes,
    Map<String, String> headers,
  ) {
    final contentType = headers['content-type']?.toLowerCase() ?? '';
    // Prefer ZIP parse if content type or magic number indicates PKZIP.
    final isZip = contentType.contains('zip') ||
        (bytes.length > 3 && bytes[0] == 0x50 && bytes[1] == 0x4B);
    if (isZip) {
      final archive = ZipDecoder().decodeBytes(bytes, verify: false);
      final results = <Uint8List>[];
      for (final file in archive.files) {
        if (!file.isFile) continue;
        final content = file.content;
        if (content is List<int>) {
          results.add(Uint8List.fromList(content));
        }
      }
      return results;
    }

    // Fallback JSON parse for potential non-zip responses.
    try {
      final data = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final image = data['image']?.toString();
      if (image != null && image.isNotEmpty) {
        return [base64Decode(image)];
      }
      final dataList = data['data'];
      if (dataList is List) {
        final results = <Uint8List>[];
        for (final item in dataList) {
          if (item is! Map<String, dynamic>) continue;
          final b64 = item['b64_json']?.toString();
          if (b64 != null && b64.isNotEmpty) {
            results.add(base64Decode(b64));
          }
        }
        return results;
      }
    } catch (_) {}
    return const <Uint8List>[];
  }

  String? _encodeToolCalls(List<ToolCall> toolCalls) {
    if (toolCalls.isEmpty) return null;
    final jsonList = <Map<String, dynamic>>[
      for (final tc in toolCalls)
        {
          'id': tc.id,
          'name': tc.name,
          'arguments': tc.arguments,
        }
    ];
    return jsonEncode(jsonList);
  }

  Future<String> sendMessage({
    required String agentId,
    required String sessionId,
    required String modelFullId, // e.g. openai:gpt-4o-mini
    required List<Map<String, dynamic>> messages,
    required String userText,
    double? temperature,
    String? token,
    Map<String, dynamic>? toolPrefs,
    String? providerApiBase,
    String? providerApiKey,
  }) async {
    final hdrs = token != null && token.trim().isNotEmpty
        ? {'Authorization': 'Bearer ${token.trim()}'}
        : null;

    // 1) 浼樺厛璧扮粺涓€ /v1/messages 绔偣
    try {
      final data = await _postJson(
          '/v1/messages',
          {
            'model': modelFullId,
            'messages': messages,
            if (temperature != null) 'temperature': temperature,
            'stream': false,
            if (providerApiBase != null && providerApiBase.trim().isNotEmpty)
              'api_base': providerApiBase.trim(),
            if (providerApiKey != null && providerApiKey.trim().isNotEmpty)
              'api_key': providerApiKey.trim(),
          },
          headers: hdrs);
      final content = (data['content'] as List?) ?? const [];
      if (content.isNotEmpty) {
        final first = content.first as Map<String, dynamic>;
        final text = first['text'] as String?;
        if (text != null) return text;
      }
      return (data['text'] as String?) ?? data.toString();
    } catch (e) {
      // 422 鎴?404 绛夋儏鍐碉紝鑷姩鍥為€€鍒?/api/chat锛圷AGNI锛氬彧鍋氬繀瑕佸厹搴曪級
    }

    // 2) 鍥為€€鍒?/api/chat 绔偣
    String provider = 'openai';
    String model = modelFullId;
    final idx = modelFullId.indexOf(':');
    if (idx > 0) {
      provider = modelFullId.substring(0, idx);
      model = modelFullId.substring(idx + 1);
    }

    // 灏嗗妯℃€?瀵硅薄鍖栫殑 messages 鍘嬪钩涓?{role, content(String)}
    String coerceContent(dynamic content) {
      if (content is String) return content;
      if (content is List) {
        final buf = StringBuffer();
        for (final part in content) {
          if (part is Map<String, dynamic>) {
            final t = (part['text'] ?? part['input_text']) as String?;
            if (t != null) buf.write(t);
          }
        }
        return buf.toString();
      }
      return content?.toString() ?? '';
    }

    final history = <Map<String, String>>[
      for (final m in messages)
        {
          'role': (m['role'] as String? ?? 'user'),
          'content': coerceContent(m['content']),
        }
    ];

    final payload = <String, dynamic>{
      'user_id': agentId,
      'session_id': sessionId,
      'message': userText,
      'history': history,
      'provider': provider,
      'model': model,
      if (toolPrefs != null && toolPrefs.isNotEmpty) 'tool_prefs': toolPrefs,
    };
    final trimmedBase = providerApiBase?.trim();
    if (trimmedBase != null && trimmedBase.isNotEmpty) {
      payload['api_base'] = trimmedBase;
    }
    final trimmedKey = providerApiKey?.trim();
    if (trimmedKey != null && trimmedKey.isNotEmpty) {
      payload['api_key'] = trimmedKey;
    }

    final data = await _postJson('/api/chat', payload, headers: hdrs);
    return (data['text'] as String?) ?? data.toString();
  }

  Future<SendMessageRichResult> sendMessageRich({
    required String agentId,
    required String sessionId,
    required String modelFullId, // e.g. openai:gpt-4o-mini
    required List<Map<String, dynamic>> messages,
    required String userText,
    double? temperature,
    double? topP, // 鏍搁噰鏍峰弬鏁?
    String? token,
    Map<String, dynamic>? toolPrefs,
    String? providerApiBase,
    String? providerApiKey,
    Map<String, dynamic>? customConfig,
    List<Map<String, dynamic>>? tools, // 鍘熺敓 Tool Calling 宸ュ叿瀹氫箟
    TraceLogger? trace, // 鍙€夌殑杩借釜鏃ュ織鍣?
    String? turnId,
    int? roundIndex,
  }) async {
    // 濡傛灉娌℃湁浼犲叆 trace锛屽垱寤轰竴涓畝鍗曠殑鏃ュ織璁板綍鍣?
    final logger =
        trace ?? AppLogger.startTrace('API调用', source: 'AgentApiClient');

    // 缁熶竴璧扮洿杩為摼璺紝閬垮厤鍓嶅悗绔弻閫氶亾鐨勯澶栧鏉傚害锛圞ISS/YAGNI锛?
    final trimmedBase = providerApiBase?.trim();
    final trimmedKey = providerApiKey?.trim();
    if (trimmedKey == null || trimmedKey.isEmpty) {
      logger.error('Missing providerApiKey for direct call');
      if (trace == null) {
        logger.end(additionalMessage: '直连调用失败');
      }
      throw StateError('Missing providerApiKey for direct call');
    }

    // 瑙ｆ瀽 provider 鍜?model
    String provider = 'openai';
    String model = modelFullId;
    final idx = modelFullId.indexOf(':');
    if (idx > 0) {
      provider = modelFullId.substring(0, idx);
      model = modelFullId.substring(idx + 1);
    }

    // 鑾峰彇瀵瑰簲鐨勯€傞厤鍣?
    final adapter = ProviderAdapterFactory.getAdapter(provider);

    final base = (trimmedBase == null || trimmedBase.isEmpty)
        ? 'https://api.openai.com/v1'
        : trimmedBase;

    // 浣跨敤閫傞厤鍣ㄦ瀯寤虹鐐癸紙榛樿 chat 绫诲瀷锛?
    final endpoint = adapter.buildEndpoint(base, modelType: 'chat');

    final directTrace = logger.startChild('直连请求');
    directTrace.info('直连目标地址', metadata: {
      'endpoint': endpoint,
      'model': modelFullId,
      'hasCustomConfig': customConfig != null,
    });

    String coerceContent(dynamic content) {
      if (content == null) return '';
      if (content is String) return content;
      if (content is List) {
        final buf = StringBuffer();
        for (final part in content) {
          if (part is Map<String, dynamic>) {
            final t = (part['text'] ?? part['input_text']) as String?;
            if (t != null) buf.write(t);
          }
        }
        return buf.toString();
      }
      if (content is Map<String, dynamic>) {
        final parts = content['parts'];
        if (parts is List) {
          final buf = StringBuffer();
          for (final part in parts) {
            if (part is Map<String, dynamic>) {
              final text = (part['text'] ?? part['input_text']) as String?;
              if (text != null) buf.write(text);
            }
          }
          return buf.toString();
        }
      }
      return content.toString();
    }

    bool isContentEmpty(dynamic content) {
      if (content == null) return true;
      if (content is String) return content.trim().isEmpty;
      if (content is List) return content.isEmpty;
      return false;
    }

    // 杞崲鍘嗗彶涓?OpenAI Chat 鏍煎紡锛堟敮鎸?content 涓?String 鎴栧妯℃€?List锛?
    // 鏀寔 role=tool 閫忎紶锛堜袱鍥炲悎宸ュ叿璋冪敤鍦烘櫙锛?
    final chatMessages = <Map<String, dynamic>>[];
    for (final m in messages) {
      final role = (m['role'] ?? '').toString();
      final content = m['content'];

      if (role == 'tool') {
        chatMessages.add(Map<String, dynamic>.from(m));
        continue;
      }

      if (role == 'function') {
        chatMessages.add(Map<String, dynamic>.from(m));
        continue;
      }

      final parts = m['parts'];
      if (parts is List && parts.isNotEmpty) {
        final normalizedRole =
            (role == 'assistant' || role == 'ai' || role == 'model')
                ? 'model'
                : 'user';
        chatMessages.add({
          'role': normalizedRole,
          'parts': parts,
        });
        continue;
      }

      if ((role == 'assistant' || role == 'ai') &&
          (m.containsKey('tool_calls') || m.containsKey('function_call'))) {
        chatMessages.add({
          'role': 'assistant',
          ...Map<String, dynamic>.from(m),
        });
        continue;
      }

      if (isContentEmpty(content)) continue;

      String r;
      if (role == 'system') {
        r = 'system';
      } else if (role == 'assistant' || role == 'ai' || role == 'model') {
        r = 'assistant';
      } else {
        r = 'user';
      }

      chatMessages.add({'role': r, 'content': content});
    }

    // 鍏煎鏃ч摼璺細褰撳巻鍙叉湯灏句笉鏄?user 鏃讹紝鎵嶆妸 userText 浣滀负鏈疆杈撳叆杩藉姞锛岄伩鍏嶉噸澶嶅彂閫?
    final trimmedUserText = userText.trim();
    final shouldAppendUserText = trimmedUserText.isNotEmpty &&
        (chatMessages.isEmpty || chatMessages.last['role'] != 'user');
    if (shouldAppendUserText) {
      chatMessages.add({'role': 'user', 'content': trimmedUserText});
    }

    // 璁＄畻鍘熷瀵硅瘽鏂囨湰闀垮害锛屽苟鐢熸垚棰勮鏃ュ織锛圞ISS锛氬彧鍋氱畝鍗曟嫾鎺ワ紱YAGNI锛氫笉鍋氬鏉傚垎鏋愶級
    int totalChars = 0;
    const maxPreviewLength = 100; // 鏃ュ織棰勮鏈€澶ч暱搴︼紝瓒呰繃鍒欐埅鏂?
    final previewBuffer = StringBuffer();
    for (final m in chatMessages) {
      final role = (m['role'] ?? '').toString();
      final contentText = coerceContent(
        m.containsKey('content') ? m['content'] : {'parts': m['parts']},
      );
      totalChars += contentText.length;
      if (previewBuffer.length < maxPreviewLength) {
        previewBuffer
          ..write('[')
          ..write(role)
          ..write('] ')
          ..write(contentText)
          ..write('\n');
      }
    }
    var promptPreview = previewBuffer.toString();
    if (promptPreview.length > maxPreviewLength) {
      promptPreview = '${promptPreview.substring(0, maxPreviewLength)}...(已截断)';
    }

    // 浣跨敤閫傞厤鍣ㄦ瀯寤鸿姹備綋
    final payload = adapter.buildRequestBody(
      model: model,
      messages: chatMessages,
      temperature: temperature,
      topP: topP,
      customConfig: customConfig,
      tools: tools,
    );
    final requestBodyJson = jsonEncode(payload);

    directTrace.info('发送直连请求', metadata: {
      'messagesCount': chatMessages.length,
      'totalChars': totalChars,
      'hasTools': tools != null && tools.isNotEmpty,
      'toolsCount': tools?.length ?? 0,
      'userText':
          userText.length > 50 ? '${userText.substring(0, 50)}...' : userText,
      'promptPreview': promptPreview,
    });

    try {
      // 浣跨敤閫傞厤鍣ㄦ瀯寤鸿姹傚ご
      final headers = adapter.buildHeaders(trimmedKey);

      final sw = Stopwatch()..start();
      final resp = await _client
          .post(
            Uri.parse(endpoint),
            headers: headers,
            body: requestBodyJson,
          )
          .timeout(timeout);
      sw.stop();

      final responseBodyStr = utf8.decode(resp.bodyBytes);

      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final data = jsonDecode(responseBodyStr) as Map<String, dynamic>;

        // 浣跨敤閫傞厤鍣ㄨВ鏋愬搷搴?
        final result = adapter.parseResponse(data);

        // 璁板綍 AI 瀵硅瘽鏃ュ織锛堝寘鍚畬鏁村師濮嬫暟鎹級
        ApiLogger.add(ApiLogEntry(
          time: DateTime.now(),
          method: 'POST',
          url: endpoint,
          status: resp.statusCode,
          durationMs: sw.elapsedMilliseconds,
          requestBody: ApiLogger.safeSnippet(requestBodyJson),
          responseBody: ApiLogger.safeSnippet(responseBodyStr),
          ok: true,
          // 瀹屾暣鐨勫師濮嬪璇濇暟鎹?
          rawContext: jsonEncode(chatMessages),
          rawAiResponse: result.text,
          rawRequestBody: requestBodyJson,
          rawResponseBody: responseBodyStr,
          rawToolCalls: _encodeToolCalls(result.toolCalls),
          sessionId: sessionId,
          turnId: turnId,
          roundIndex: roundIndex,
          eventType: 'round',
        ));

        directTrace.info('直连响应成功', metadata: {
          'statusCode': resp.statusCode,
          'textLength': result.text.length,
          'toolCalls': result.toolCalls.length,
          'text': result.text.length > 100
              ? '${result.text.substring(0, 100)}...'
              : result.text,
        });
        directTrace.end(additionalMessage: '直连调用完成');

        // 濡傛灉 logger 鏄嚜宸卞垱寤虹殑锛岄渶瑕佺粨鏉熷畠
        if (trace == null) logger.end();

        return SendMessageRichResult(
          text: result.text,
          toolResults: result.toolResults,
          toolCalls: result.toolCalls,
          rawResponse: result.rawResponse,
        );
      }

      // 璁板綍澶辫触鐨?API 鏃ュ織
      ApiLogger.add(ApiLogEntry(
        time: DateTime.now(),
        method: 'POST',
        url: endpoint,
        status: resp.statusCode,
        durationMs: sw.elapsedMilliseconds,
        requestBody: ApiLogger.safeSnippet(requestBodyJson),
        responseBody: ApiLogger.safeSnippet(responseBodyStr),
        ok: false,
        rawContext: jsonEncode(chatMessages),
        rawRequestBody: requestBodyJson,
        rawResponseBody: responseBodyStr,
        sessionId: sessionId,
        turnId: turnId,
        roundIndex: roundIndex,
        eventType: 'round',
      ));

      // HTTP 閿欒鐩存帴鎶涘嚭锛岃涓婂眰鏄剧ず鐪熷疄鍘熷洜
      directTrace.error('直连请求失败', metadata: {
        'statusCode': resp.statusCode,
        'body': resp.body,
      });
      throw Exception('HTTP ${resp.statusCode}: ${resp.body}');
    } catch (e) {
      directTrace.error('直连模式出现异常', metadata: {
        'error': e.toString(),
      });
      directTrace.end(additionalMessage: '直连失败');
      if (trace == null) {
        logger.end(additionalMessage: '直连调用失败');
      }
      rethrow;
    }
  }

  /// 娴佸紡鍙戦€佹秷鎭紙鏀寔鍒嗘锛? 杩斿洖娑堟伅鍧楁祦
  ///
  /// 搴旂敤鍘熷垯锛?
  /// - KISS: 绠€鍗曠殑 SSE 瑙ｆ瀽锛屽彧澶勭悊蹇呰鐨勫瓧娈?
  /// - SOLID: 鑱岃矗鍗曚竴锛屽彧璐熻矗鎺ユ敹鍜岃В鏋?SSE 娴?
  Stream<Map<String, dynamic>> sendMessageStream({
    required String agentId,
    required String sessionId,
    required String modelFullId,
    required List<Map<String, dynamic>> messages,
    required String userText,
    double? temperature,
    String? token,
    Map<String, dynamic>? toolPrefs,
    String? providerApiBase,
    String? providerApiKey,
  }) async* {
    final uri = _uri('/api/chat/stream');

    // 鏋勫缓璇锋眰浣擄紙涓?sendMessageRich 绫讳技锛?
    String provider = 'openai';
    String model = modelFullId;
    final idx = modelFullId.indexOf(':');
    if (idx > 0) {
      provider = modelFullId.substring(0, idx);
      model = modelFullId.substring(idx + 1);
    }

    String coerceContent(dynamic content) {
      if (content is String) return content;
      if (content is List) {
        final buf = StringBuffer();
        for (final part in content) {
          if (part is Map<String, dynamic>) {
            final t = (part['text'] ?? part['input_text']) as String?;
            if (t != null) buf.write(t);
          }
        }
        return buf.toString();
      }
      return content?.toString() ?? '';
    }

    final history = <Map<String, String>>[
      for (final m in messages)
        {
          'role': (m['role'] as String? ?? 'user'),
          'content': coerceContent(m['content']),
        }
    ];

    final payload = <String, dynamic>{
      'user_id': agentId,
      'session_id': sessionId,
      'message': userText,
      'history': history,
      'provider': provider,
      'model': model,
      if (toolPrefs != null && toolPrefs.isNotEmpty) 'tool_prefs': toolPrefs,
    };

    final trimmedBase = providerApiBase?.trim();
    if (trimmedBase != null && trimmedBase.isNotEmpty) {
      payload['api_base'] = trimmedBase;
    }
    final trimmedKey = providerApiKey?.trim();
    if (trimmedKey != null && trimmedKey.isNotEmpty) {
      payload['api_key'] = trimmedKey;
    }

    final hdrs = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'text/event-stream',
      if (token != null && token.trim().isNotEmpty)
        'Authorization': 'Bearer ${token.trim()}',
    };

    // 鍙戦€?SSE 璇锋眰
    final request = http.Request('POST', uri);
    request.headers.addAll(hdrs);
    request.body = jsonEncode(payload);

    final response = await _client.send(request).timeout(timeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('HTTP ${response.statusCode}');
    }

    // 瑙ｆ瀽 SSE 娴?
    await for (final chunk in response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (chunk.isEmpty) continue;

      // SSE 鏍煎紡: data: {json}
      if (chunk.startsWith('data: ')) {
        final data = chunk.substring(6).trim();

        // 缁撴潫鏍囪
        if (data == '[DONE]') {
          _evt('sse:done', {'path': '/api/chat/stream'}, level: 'INFO');
          break;
        }

        try {
          final json = jsonDecode(data) as Map<String, dynamic>;
          _evt(
              'sse:event',
              {
                'keys': json.keys.toList(),
                'type': json['type'],
              },
              level: 'DBUG');
          yield json;
        } catch (_) {
          // 蹇界暐瑙ｆ瀽閿欒
        }
      }
    }
  }

  /// 鍚屾瑙﹀彂鍣ㄥ績璺筹紙鐢ㄤ簬浜戠鎺ョ鍒ゅ畾锛?
  Future<void> syncTriggerHeartbeat(DateTime timestamp, {String? token}) async {
    try {
      final uri = _uri('/api/v1/sync/trigger_heartbeat');
      final headers = <String, String>{
        if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
      };

      await _client
          .post(
            uri,
            headers: headers,
            body: jsonEncode({'timestamp': timestamp.toIso8601String()}),
          )
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      // 蹇冭烦澶辫触涓嶅簲闃绘柇娴佺▼锛屼粎璁板綍鏃ュ織
      _evt('syncTriggerHeartbeat', {'error': e.toString()}, level: 'WARN');
    }
  }
}
