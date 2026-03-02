import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import '../config.dart';
import '../api_logger.dart';
import '../app_logger.dart';
import '../utils/content_normalizer.dart';
import 'providers/provider_adapter_factory.dart';
import 'providers/provider_adapter.dart' show ToolCall;

class SendMessageRichResult {
  final String text;
  final List<Map<String, dynamic>> toolResults;
  final List<ToolCall> toolCalls; // AI 请求执行的工具调用
  final Map<String, dynamic>? rawResponse; // 原始响应（用于两回合工具调用）

  const SendMessageRichResult({
    required this.text,
    required this.toolResults,
    this.toolCalls = const [],
    this.rawResponse,
  });

  /// 是否有待执行的工具调用
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

  // 事件日志（文本风格；不引入新依赖）
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
    final isV4 = _isNovelAiV4Model(model);
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
      'ucPreset': 0,
      'legacy': false,
      'legacy_v3_extend': false,
      'noise_schedule': 'karras',
      'add_original_image': false,
      'cfg_rescale': 0,
      'sm': false,
      'sm_dyn': false,
      'dynamic_thresholding': false,
      'prefer_brownian': true,
      'deliberate_euler_ancestral_bug': false,
      'autoSmea': false,
      if (seed != null) 'seed': seed,
      if (negativePromptValue != null && negativePromptValue.isNotEmpty)
        'negative_prompt': negativePromptValue,
    };
    if (isV4) {
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

  Map<String, dynamic> _buildRequestDiagnostics({
    required String endpoint,
    required String provider,
    required String modelFullId,
    required String model,
    required String requestBodyJson,
    required Map<String, dynamic> payload,
    required List<Map<String, dynamic>> chatMessages,
    required Map<String, dynamic>? customConfig,
    required List<Map<String, dynamic>>? tools,
    required String? providerApiBase,
    Map<String, String>? headers,
  }) {
    final messageRoles = <String>[
      for (final message in chatMessages) (message['role'] ?? '').toString(),
    ];
    final messagesWithParts = chatMessages.where((message) {
      if (message['parts'] is List) return true;
      final content = message['content'];
      if (content is! List) return false;
      return content.any((item) => item is Map && item.containsKey('type'));
    }).length;
    final messagesWithToolCalls = chatMessages.where((message) {
      return message.containsKey('tool_calls') ||
          message.containsKey('function_call');
    }).length;

    final diagnostics = <String, dynamic>{
      'endpoint': endpoint,
      'provider': provider,
      'modelFullId': modelFullId,
      'model': model,
      'providerApiBase': providerApiBase,
      'providerApiBaseLooksLikeEndpoint':
          _looksLikeEndpointUrl(providerApiBase),
      'payloadKeys': payload.keys.toList(),
      'requestBodyBytes': utf8.encode(requestBodyJson).length,
      'requestBodyPreview': ApiLogger.safeSnippet(requestBodyJson, max: 2000),
      'messagesCount': chatMessages.length,
      'messageRoles': messageRoles,
      'messagesWithParts': messagesWithParts,
      'messagesWithToolCalls': messagesWithToolCalls,
      'toolsCount': tools?.length ?? 0,
      'customConfigKeys': customConfig?.keys.toList() ?? const <String>[],
    };
    if (headers != null && headers.isNotEmpty) {
      diagnostics['headerKeys'] = headers.keys.toList();
    }
    return diagnostics;
  }

  bool _looksLikeEndpointUrl(String? value) {
    final text = value?.trim().toLowerCase() ?? '';
    if (text.isEmpty) return false;
    return text.contains('/chat/completions') ||
        text.contains('/responses') ||
        text.contains('/v1/messages');
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

    // 1) 优先走统一 /v1/messages 端点
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
      // 422 或 404 等情况，自动回退到 /api/chat（YAGNI：只做必要兜底）
    }

    // 2) 回退到 /api/chat 端点
    String provider = 'openai';
    String model = modelFullId;
    final idx = modelFullId.indexOf(':');
    if (idx > 0) {
      provider = modelFullId.substring(0, idx);
      model = modelFullId.substring(idx + 1);
    }

    // 将多模态对象化的 messages 压平为 {role, content(String)}
    final history = <Map<String, String>>[
      for (final m in messages)
        {
          'role': (m['role'] as String? ?? 'user'),
          'content': ContentNormalizer.coerceToText(m['content']),
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
    double? topP, // 核采样参数
    String? token,
    Map<String, dynamic>? toolPrefs,
    String? providerApiBase,
    String? providerApiKey,
    Map<String, dynamic>? customConfig,
    List<Map<String, dynamic>>? tools, // 原生 Tool Calling 工具定义
    TraceLogger? trace, // 可选的追踪日志器
    String? turnId,
    int? roundIndex,
  }) async {
    // 如果没有传入 trace，创建一个简单的日志记录器
    final logger =
        trace ?? AppLogger.startTrace('API调用', source: 'AgentApiClient');

    // 统一走直连链路，避免前后端双通道的额外复杂度（KISS/YAGNI）
    final trimmedBase = providerApiBase?.trim();
    final trimmedKey = providerApiKey?.trim();
    if (trimmedKey == null || trimmedKey.isEmpty) {
      logger.error('Missing providerApiKey for direct call');
      if (trace == null) {
        logger.end(additionalMessage: '直连调用失败');
      }
      throw StateError('Missing providerApiKey for direct call');
    }

    // 解析 provider 和 model
    String provider = 'openai';
    String model = modelFullId;
    final idx = modelFullId.indexOf(':');
    if (idx > 0) {
      provider = modelFullId.substring(0, idx);
      model = modelFullId.substring(idx + 1);
    }

    // 获取对应的适配器
    final adapter = ProviderAdapterFactory.getAdapter(provider);

    final base = (trimmedBase == null || trimmedBase.isEmpty)
        ? 'https://api.openai.com/v1'
        : trimmedBase;
    // 解析 provider 和 model
    // 使用适配器构建端点（默认 chat 类型）
    final endpoint = adapter.buildEndpoint(base, modelType: 'chat');

    final directTrace = logger.startChild('直连请求');
    directTrace.info('直连目标地址', metadata: {
      'endpoint': endpoint,
      'model': modelFullId,
      'hasCustomConfig': customConfig != null,
    });

    // 转换历史为 OpenAI Chat 格式（支持 content 为 String 或多模态 List）
    // 支持 role=tool 透传（两回合工具调用场景）
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

      if (ContentNormalizer.isEmpty(content)) continue;

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

    // 兼容旧链路：当历史末尾不是 user 时，才把 userText 作为本轮输入追加，避免重复发送
    final trimmedUserText = userText.trim();
    final shouldAppendUserText = trimmedUserText.isNotEmpty &&
        (chatMessages.isEmpty || chatMessages.last['role'] != 'user');
    if (shouldAppendUserText) {
      chatMessages.add({'role': 'user', 'content': trimmedUserText});
    }

    // 计算原始对话文本长度，并生成预览日志（KISS：只做简单拼接；YAGNI：不做复杂分析）
    int totalChars = 0;
    const maxPreviewLength = 100; // 日志预览最大长度，超过则截断
    final previewBuffer = StringBuffer();
    for (final m in chatMessages) {
      final role = (m['role'] ?? '').toString();
      final contentText = ContentNormalizer.coerceToText(
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

    // 使用适配器构建请求体
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
      // 使用适配器构建请求头
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

      final requestDiagnostics = _buildRequestDiagnostics(
        endpoint: endpoint,
        provider: provider,
        modelFullId: modelFullId,
        model: model,
        requestBodyJson: requestBodyJson,
        payload: payload,
        chatMessages: chatMessages,
        customConfig: customConfig,
        tools: tools,
        providerApiBase: trimmedBase,
        headers: headers,
      );

      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final data = jsonDecode(responseBodyStr) as Map<String, dynamic>;

        // 使用适配器解析响应
        final result = adapter.parseResponse(data);

        // 记录 AI 对话日志（包含完整原始数据）
        ApiLogger.add(ApiLogEntry(
          time: DateTime.now(),
          method: 'POST',
          url: endpoint,
          status: resp.statusCode,
          durationMs: sw.elapsedMilliseconds,
          requestBody: ApiLogger.safeSnippet(requestBodyJson),
          responseBody: ApiLogger.safeSnippet(responseBodyStr),
          ok: true,
          // 完整的原始对话数据
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

        // 如果 logger 是自己创建的，需要结束它
        if (trace == null) logger.end();

        return SendMessageRichResult(
          text: result.text,
          toolResults: result.toolResults,
          toolCalls: result.toolCalls,
          rawResponse: result.rawResponse,
        );
      }

      // 记录失败的 API 日志
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

      // HTTP 错误直接抛出，让上层显示真实原因
      directTrace.error('直连请求失败', metadata: {
        'statusCode': resp.statusCode,
        'responseBody': ApiLogger.safeSnippet(responseBodyStr, max: 2000),
        ...requestDiagnostics,
      });
      throw Exception('HTTP ${resp.statusCode}: ${resp.body}');
    } catch (e) {
      final requestDiagnostics = _buildRequestDiagnostics(
        endpoint: endpoint,
        provider: provider,
        modelFullId: modelFullId,
        model: model,
        requestBodyJson: requestBodyJson,
        payload: payload,
        chatMessages: chatMessages,
        customConfig: customConfig,
        tools: tools,
        providerApiBase: trimmedBase,
      );
      directTrace.error('直连模式出现异常', metadata: {
        'error': e.toString(),
        ...requestDiagnostics,
      });
      directTrace.end(additionalMessage: '直连失败');
      if (trace == null) {
        logger.end(additionalMessage: '直连调用失败');
      }
      rethrow;
    }
  }

  /// 直连 Provider 的流式调用（OpenAI 兼容 SSE）
  ///
  /// 说明：
  /// - 仅将 `delta.content` 通过 [onTextDelta] 输出给 UI；
  /// - `tool_calls` 增量只在内部聚合，最终写入返回值，不进入用户可见文本。
  Future<SendMessageRichResult> sendMessageRichStream({
    required String agentId,
    required String sessionId,
    required String modelFullId,
    required List<Map<String, dynamic>> messages,
    required String userText,
    double? temperature,
    double? topP,
    String? token,
    Map<String, dynamic>? toolPrefs,
    String? providerApiBase,
    String? providerApiKey,
    Map<String, dynamic>? customConfig,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onTextDelta,
    void Function()? onToolCallsDetected,
    TraceLogger? trace,
    String? turnId,
    int? roundIndex,
  }) async {
    final logger =
        trace ?? AppLogger.startTrace('API流式调用', source: 'AgentApiClient');
    final directTrace = logger.startChild('直连流式请求');

    final trimmedBase = providerApiBase?.trim();
    final trimmedKey = providerApiKey?.trim();
    if (trimmedKey == null || trimmedKey.isEmpty) {
      directTrace.error('Missing providerApiKey for direct stream');
      directTrace.end(additionalMessage: '直连流式失败');
      if (trace == null) {
        logger.end(additionalMessage: '直连流式调用失败');
      }
      throw StateError('Missing providerApiKey for direct stream');
    }

    String provider = 'openai';
    String model = modelFullId;
    final idx = modelFullId.indexOf(':');
    if (idx > 0) {
      provider = modelFullId.substring(0, idx);
      model = modelFullId.substring(idx + 1);
    }

    final adapter = ProviderAdapterFactory.getAdapter(provider);
    if (adapter.name != 'openai') {
      directTrace.error('provider stream unsupported', metadata: {
        'provider': provider,
        'adapter': adapter.name,
      });
      directTrace.end(additionalMessage: '直连流式失败');
      if (trace == null) {
        logger.end(additionalMessage: '直连流式调用失败');
      }
      throw UnsupportedError(
          'Streaming is only supported for OpenAI-compatible providers');
    }

    final base = (trimmedBase == null || trimmedBase.isEmpty)
        ? 'https://api.openai.com/v1'
        : trimmedBase;
    final endpoint = adapter.buildEndpoint(base, modelType: 'chat');

    final chatMessages = <Map<String, dynamic>>[];
    for (final m in messages) {
      final role = (m['role'] ?? '').toString();
      final content = m['content'];

      if (role == 'tool' || role == 'function') {
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

      if (ContentNormalizer.isEmpty(content)) continue;

      final normalizedRole = switch (role) {
        'system' => 'system',
        'assistant' || 'ai' || 'model' => 'assistant',
        _ => 'user',
      };
      chatMessages.add({'role': normalizedRole, 'content': content});
    }

    final trimmedUserText = userText.trim();
    final shouldAppendUserText = trimmedUserText.isNotEmpty &&
        (chatMessages.isEmpty || chatMessages.last['role'] != 'user');
    if (shouldAppendUserText) {
      chatMessages.add({'role': 'user', 'content': trimmedUserText});
    }

    final payload = adapter.buildRequestBody(
      model: model,
      messages: chatMessages,
      temperature: temperature,
      topP: topP,
      customConfig: customConfig,
      tools: tools,
    );
    payload['stream'] = true;
    final requestBodyJson = jsonEncode(payload);

    final headers = <String, String>{
      ...adapter.buildHeaders(trimmedKey),
      'Accept': 'text/event-stream',
    };
    // 直连流式优先使用 provider 自身鉴权；仅在未提供 Authorization 时回退到 token。
    if (token != null &&
        token.trim().isNotEmpty &&
        !headers.containsKey('Authorization')) {
      headers['Authorization'] = 'Bearer ${token.trim()}';
    }

    directTrace.info('发送直连流式请求', metadata: {
      'endpoint': endpoint,
      'model': modelFullId,
      'messagesCount': chatMessages.length,
      'hasTools': tools != null && tools.isNotEmpty,
      'toolsCount': tools?.length ?? 0,
    });

    final sw = Stopwatch()..start();
    final request = http.Request('POST', Uri.parse(endpoint));
    request.headers.addAll(headers);
    request.body = requestBodyJson;
    final requestDiagnostics = _buildRequestDiagnostics(
      endpoint: endpoint,
      provider: provider,
      modelFullId: modelFullId,
      model: model,
      requestBodyJson: requestBodyJson,
      payload: payload,
      chatMessages: chatMessages,
      customConfig: customConfig,
      tools: tools,
      providerApiBase: trimmedBase,
      headers: headers,
    );

    try {
      final response = await _client.send(request).timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final errBody = utf8.decode(await response.stream.toBytes());
        sw.stop();
        ApiLogger.add(ApiLogEntry(
          time: DateTime.now(),
          method: 'POST',
          url: endpoint,
          status: response.statusCode,
          durationMs: sw.elapsedMilliseconds,
          requestBody: ApiLogger.safeSnippet(requestBodyJson),
          responseBody: ApiLogger.safeSnippet(errBody),
          ok: false,
          rawContext: jsonEncode(chatMessages),
          rawRequestBody: requestBodyJson,
          rawResponseBody: errBody,
          sessionId: sessionId,
          turnId: turnId,
          roundIndex: roundIndex,
          eventType: 'round_stream',
        ));
        directTrace.error('直连流式请求失败(非2xx)', metadata: {
          'statusCode': response.statusCode,
          'responseBody': ApiLogger.safeSnippet(errBody, max: 2000),
          ...requestDiagnostics,
        });
        throw Exception('HTTP ${response.statusCode}: $errBody');
      }

      final text = StringBuffer();
      final reasoning = StringBuffer();
      final toolAggregator = _StreamingToolCallAggregator();
      final textDeltaNormalizer = _StreamingTextDeltaNormalizer();
      var done = false;
      var toolCallsObserved = false;
      final dataLines = <String>[];
      final rawStreamEvents = <Object?>[];

      void emitTextDelta(String delta) {
        if (delta.isEmpty) return;
        final normalized = textDeltaNormalizer.normalize(delta);
        if (normalized.isEmpty) return;
        text.write(normalized);
        onTextDelta?.call(normalized);
      }

      void emitReasoningDelta(String delta) {
        if (delta.isEmpty) return;
        reasoning.write(delta);
      }

      void markToolCallsObserved() {
        if (toolCallsObserved) return;
        toolCallsObserved = true;
        onToolCallsDetected?.call();
      }

      void consumeToolCalls(dynamic rawCalls) {
        if (rawCalls is List) {
          if (rawCalls.isEmpty) return;
          toolAggregator.consumeToolCalls(rawCalls);
          markToolCallsObserved();
        }
      }

      void consumeLegacyFunctionCall(dynamic rawCall) {
        if (rawCall is Map) {
          toolAggregator.consumeLegacyFunctionCall(rawCall);
          markToolCallsObserved();
        }
      }

      void handleEventPayload(String payload) {
        final trimmed = payload.trim();
        if (trimmed.isEmpty) return;
        if (trimmed == '[DONE]') {
          rawStreamEvents.add('[DONE]');
          done = true;
          return;
        }

        Map<String, dynamic> evt;
        try {
          evt = jsonDecode(trimmed) as Map<String, dynamic>;
          rawStreamEvents.add(evt);
        } catch (_) {
          rawStreamEvents.add({
            '_raw': trimmed,
            '_parseError': true,
          });
          return;
        }

        var handledChoice = false;
        var emittedTextFromChoices = false;
        final choices = evt['choices'];
        if (choices is List && choices.isNotEmpty) {
          final first = choices.first;
          if (first is Map) {
            handledChoice = true;
            final choice =
                Map<String, dynamic>.from(first.cast<String, dynamic>());
            final delta = choice['delta'];
            final message = choice['message'];

            var emittedTextFromDelta = false;
            var emittedReasoningFromDelta = false;
            if (delta is Map) {
              final deltaMap =
                  Map<String, dynamic>.from(delta.cast<String, dynamic>());
              final textDelta = _extractStreamingText(deltaMap['content']);
              if (textDelta.isNotEmpty) {
                emitTextDelta(textDelta);
                emittedTextFromDelta = true;
                emittedTextFromChoices = true;
              }
              final reasoningDelta =
                  _extractStreamingText(deltaMap['reasoning_content']);
              if (reasoningDelta.isNotEmpty) {
                emitReasoningDelta(reasoningDelta);
                emittedReasoningFromDelta = true;
              }
              consumeToolCalls(deltaMap['tool_calls']);
              consumeLegacyFunctionCall(deltaMap['function_call']);
            }

            if (!emittedTextFromDelta && message is Map) {
              final messageMap =
                  Map<String, dynamic>.from(message.cast<String, dynamic>());
              final fallbackText = _extractStreamingText(messageMap['content']);
              if (fallbackText.isNotEmpty) {
                emitTextDelta(fallbackText);
                emittedTextFromChoices = true;
              }
              if (!emittedReasoningFromDelta) {
                final fallbackReasoning =
                    _extractStreamingText(messageMap['reasoning_content']);
                if (fallbackReasoning.isNotEmpty) {
                  emitReasoningDelta(fallbackReasoning);
                }
              }
              consumeToolCalls(messageMap['tool_calls']);
              consumeLegacyFunctionCall(messageMap['function_call']);
            } else if (message is Map) {
              final messageMap =
                  Map<String, dynamic>.from(message.cast<String, dynamic>());
              if (!emittedReasoningFromDelta) {
                final fallbackReasoning =
                    _extractStreamingText(messageMap['reasoning_content']);
                if (fallbackReasoning.isNotEmpty) {
                  emitReasoningDelta(fallbackReasoning);
                }
              }
              consumeToolCalls(messageMap['tool_calls']);
              consumeLegacyFunctionCall(messageMap['function_call']);
            }
          }
        }

        // 兜底兼容：部分服务商会把字段放在根层
        consumeToolCalls(evt['tool_calls']);
        consumeLegacyFunctionCall(evt['function_call']);
        final rootReasoningContent = _extractStreamingText(
          evt['reasoning_content'],
        );
        if (rootReasoningContent.isNotEmpty) {
          emitReasoningDelta(rootReasoningContent);
        }

        // Responses API 风格增量事件（兼容中转层）
        final eventType = evt['type']?.toString() ?? '';
        if (eventType == 'response.reasoning.delta' ||
            eventType == 'response.reasoning_text.delta') {
          final rootReasoningDelta = _extractStreamingText(evt['delta']);
          if (rootReasoningDelta.isNotEmpty) {
            emitReasoningDelta(rootReasoningDelta);
          }
        }

        if (eventType == 'response.output_text.delta') {
          if (!emittedTextFromChoices) {
            final rootDelta = _extractStreamingText(evt['delta']);
            if (rootDelta.isNotEmpty) {
              emitTextDelta(rootDelta);
            }
          }
        } else if (!handledChoice || !emittedTextFromChoices) {
          final rootDelta = _extractStreamingText(evt['delta']);
          if (rootDelta.isNotEmpty) {
            emitTextDelta(rootDelta);
          } else {
            final rootContent = _extractStreamingText(evt['content']);
            if (rootContent.isNotEmpty) {
              emitTextDelta(rootContent);
            }
          }
        }
      }

      void flushEvent() {
        if (dataLines.isEmpty || done) {
          dataLines.clear();
          return;
        }
        final payload = dataLines.join('\n');
        dataLines.clear();
        handleEventPayload(payload);
      }

      await for (final line in response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (done) break;
        if (line.isEmpty) {
          flushEvent();
          continue;
        }
        if (line.startsWith(':')) continue;
        if (line.startsWith('data:')) {
          dataLines.add(line.substring(5).trimLeft());
          continue;
        }
      }
      flushEvent();

      sw.stop();
      final builtToolCalls = toolAggregator.build();
      final finalText = text.toString();
      final finalReasoning = reasoning.toString();
      final assistantMessage = <String, dynamic>{
        'role': 'assistant',
        'content': finalText.isEmpty ? null : finalText,
        if (finalReasoning.isNotEmpty) 'reasoning_content': finalReasoning,
        if (builtToolCalls.isNotEmpty)
          'tool_calls': [
            for (final call in builtToolCalls) call.toOpenAIFormat(),
          ],
      };
      final synthesizedRawResponse = <String, dynamic>{
        'choices': [
          {'message': assistantMessage}
        ],
      };
      final rawResponseBodyForLog = jsonEncode({
        'streamEvents': rawStreamEvents,
      });

      ApiLogger.add(ApiLogEntry(
        time: DateTime.now(),
        method: 'POST',
        url: endpoint,
        status: response.statusCode,
        durationMs: sw.elapsedMilliseconds,
        requestBody: ApiLogger.safeSnippet(requestBodyJson),
        responseBody: '[stream]',
        ok: true,
        rawContext: jsonEncode(chatMessages),
        rawAiResponse: finalText,
        rawRequestBody: requestBodyJson,
        rawResponseBody: rawResponseBodyForLog,
        rawToolCalls: _encodeToolCalls(builtToolCalls),
        sessionId: sessionId,
        turnId: turnId,
        roundIndex: roundIndex,
        eventType: 'round_stream',
      ));

      directTrace.info('直连流式响应成功', metadata: {
        'textLength': finalText.length,
        'reasoningLength': finalReasoning.length,
        'toolCalls': builtToolCalls.length,
      });
      directTrace.end(additionalMessage: '直连流式调用完成');
      if (trace == null) logger.end();

      return SendMessageRichResult(
        text: finalText,
        toolResults: const <Map<String, dynamic>>[],
        toolCalls: builtToolCalls,
        rawResponse: synthesizedRawResponse,
      );
    } catch (e) {
      sw.stop();
      directTrace.error('直连流式请求失败', metadata: {
        'error': e.toString(),
        ...requestDiagnostics,
      });
      directTrace.end(additionalMessage: '直连流式失败');
      if (trace == null) {
        logger.end(additionalMessage: '直连流式调用失败');
      }
      rethrow;
    }
  }

  /// 流式发送消息（支持分块），返回消息块流
  ///
  /// 应用原则：
  /// - KISS: 简单的 SSE 解析，只处理必要的字段
  /// - SOLID: 职责单一，只负责接收和解析 SSE 流
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

    // 构建请求体（与 sendMessageRich 类似）
    String provider = 'openai';
    String model = modelFullId;
    final idx = modelFullId.indexOf(':');
    if (idx > 0) {
      provider = modelFullId.substring(0, idx);
      model = modelFullId.substring(idx + 1);
    }

    final history = <Map<String, String>>[
      for (final m in messages)
        {
          'role': (m['role'] as String? ?? 'user'),
          'content': ContentNormalizer.coerceToText(m['content']),
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

    // 发送 SSE 请求
    final request = http.Request('POST', uri);
    request.headers.addAll(hdrs);
    request.body = jsonEncode(payload);

    final response = await _client.send(request).timeout(timeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('HTTP ${response.statusCode}');
    }

    // 解析 SSE 流
    await for (final chunk in response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (chunk.isEmpty) continue;

      // SSE 格式: data: {json}
      if (chunk.startsWith('data: ')) {
        final data = chunk.substring(6).trim();

        // 结束标记
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
          // 忽略解析错误
        }
      }
    }
  }

  /// 同步触发器心跳（用于云端接管判定）
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
      // 心跳失败不应阻断流程，仅记录日志
      _evt('syncTriggerHeartbeat', {'error': e.toString()}, level: 'WARN');
    }
  }
}

class _StreamingToolCallAggregator {
  final Map<int, _StreamingToolCallState> _toolCallsByIndex = {};
  final Map<String, int> _toolCallIndexById = {};
  int _nextImplicitIndex = 0;
  _StreamingToolCallState? _legacyFunctionCall;

  void consumeToolCalls(List<dynamic> rawCalls) {
    for (var position = 0; position < rawCalls.length; position++) {
      final item = rawCalls[position];
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item.cast<String, dynamic>());
      final index = _resolveIndex(map, fallbackPosition: position);
      final state =
          _toolCallsByIndex.putIfAbsent(index, () => _StreamingToolCallState());
      state.consume(map);
      final id = map['id']?.toString().trim() ?? '';
      if (id.isNotEmpty) {
        _toolCallIndexById[id] = index;
      }
      if (index >= _nextImplicitIndex) {
        _nextImplicitIndex = index + 1;
      }
    }
  }

  void consumeLegacyFunctionCall(Map<dynamic, dynamic> rawCall) {
    final map = Map<String, dynamic>.from(rawCall.cast<String, dynamic>());
    final state = _legacyFunctionCall ??= _StreamingToolCallState();
    state.consumeLegacy(map);
  }

  List<ToolCall> build() {
    final calls = <ToolCall>[
      for (final entry
          in _toolCallsByIndex.entries.toList()
            ..sort((a, b) => a.key.compareTo(b.key)))
        entry.value.buildToolCall(fallbackIndex: entry.key + 1),
    ];
    if (calls.isNotEmpty) return calls;
    if (_legacyFunctionCall == null) return const <ToolCall>[];
    return <ToolCall>[
      _legacyFunctionCall!.buildToolCall(fallbackIndex: 1),
    ];
  }

  int _resolveIndex(
    Map<String, dynamic> rawCall, {
    required int fallbackPosition,
  }) {
    final explicit = rawCall['index'];
    if (explicit is num) return explicit.toInt();

    final id = rawCall['id']?.toString().trim() ?? '';
    if (id.isNotEmpty) {
      final existing = _toolCallIndexById[id];
      if (existing != null) return existing;
      final assigned = _nextImplicitIndex++;
      _toolCallIndexById[id] = assigned;
      return assigned;
    }

    return fallbackPosition;
  }
}

class _StreamingToolCallState {
  String _id = '';
  String _name = '';
  final StringBuffer _arguments = StringBuffer();

  void consume(Map<String, dynamic> rawCall) {
    final id = rawCall['id']?.toString().trim() ?? '';
    if (id.isNotEmpty) _id = id;

    final function = rawCall['function'];
    if (function is Map) {
      final map = Map<String, dynamic>.from(function.cast<String, dynamic>());
      final namePart = map['name']?.toString() ?? '';
      if (namePart.isNotEmpty) {
        _name = _name.isEmpty ? namePart : '$_name$namePart';
      }
      final argsPart = map['arguments']?.toString() ?? '';
      if (argsPart.isNotEmpty) {
        _arguments.write(argsPart);
      }
      return;
    }

    // 兼容非 OpenAI 标准结构（根层直接给 name/arguments）
    final namePart =
        rawCall['name']?.toString() ?? rawCall['tool_name']?.toString() ?? '';
    if (namePart.isNotEmpty) {
      _name = _name.isEmpty ? namePart : '$_name$namePart';
    }
    final argsPart =
        rawCall['arguments']?.toString() ?? rawCall['args']?.toString() ?? '';
    if (argsPart.isNotEmpty) {
      _arguments.write(argsPart);
    }
  }

  void consumeLegacy(Map<String, dynamic> rawCall) {
    final namePart = rawCall['name']?.toString() ?? '';
    if (namePart.isNotEmpty) {
      _name = _name.isEmpty ? namePart : '$_name$namePart';
    }
    final argsPart = rawCall['arguments']?.toString() ?? '';
    if (argsPart.isNotEmpty) {
      _arguments.write(argsPart);
    }
  }

  ToolCall buildToolCall({required int fallbackIndex}) {
    return ToolCall(
      id: _id.isNotEmpty ? _id : 'stream_tool_call_$fallbackIndex',
      name: _name,
      arguments: _parseArguments(_arguments.toString()),
    );
  }

  Map<String, dynamic> _parseArguments(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return const <String, dynamic>{};
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {}
    return <String, dynamic>{'_raw': trimmed};
  }
}

class _StreamingTextDeltaNormalizer {
  String _fullText = '';

  String normalize(String incoming) {
    if (incoming.isEmpty) return '';

    if (_fullText.isEmpty) {
      _fullText = incoming;
      return incoming;
    }

    if (incoming == _fullText) {
      return '';
    }

    // Compatible providers may return cumulative text each event.
    // Keep only the incremental suffix to avoid repeated content.
    if (incoming.startsWith(_fullText)) {
      final suffix = incoming.substring(_fullText.length);
      _fullText = incoming;
      return suffix;
    }

    // Ignore retransmitted tails.
    if (_fullText.endsWith(incoming)) {
      return '';
    }

    _fullText += incoming;
    return incoming;
  }
}

String _extractStreamingText(dynamic value) {
  if (value == null) return '';
  if (value is String) return value;

  if (value is Map) {
    final map = Map<String, dynamic>.from(value.cast<String, dynamic>());
    return _extractStreamingText(
      map['text'] ?? map['delta'] ?? map['content'],
    );
  }

  if (value is List) {
    final buffer = StringBuffer();
    for (final item in value) {
      final chunk = _extractStreamingText(item);
      if (chunk.isNotEmpty) {
        buffer.write(chunk);
      }
    }
    return buffer.toString();
  }

  return '';
}
