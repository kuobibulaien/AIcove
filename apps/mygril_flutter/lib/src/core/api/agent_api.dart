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

  // 事件日志（文本行风格；不引入新依赖）
  void _evt(String name, Map<String, Object?> data, {String level = 'INFO'}) {
    final now = DateTime.now();
    final ts =
        '[${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}]';
    const source = 'AgentApiClient';
    final parts = <String>[];
    data.forEach((k, v) {
      if (v == null) return;
      final val = v is String && v.length > 120 ? '${v.substring(0, 120)}…' : v;
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

    // 将多模态/对象化的 messages 压平为 {role, content(String)}
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
    double? topP, // 核采样参数
    String? token,
    Map<String, dynamic>? toolPrefs,
    String? providerApiBase,
    String? providerApiKey,
    Map<String, dynamic>? customConfig,
    List<Map<String, dynamic>>? tools, // 原生 Tool Calling 工具定义
    TraceLogger? trace, // 可选的追踪日志器
  }) async {
    // 如果没有传入 trace，创建一个简单的日志记录器
    final logger =
        trace ?? AppLogger.startTrace('API调用', source: 'AgentApiClient');

    // 统一走直连链路，避免前后端双通道的额外复杂度（KISS/YAGNI）
    final trimmedBase = providerApiBase?.trim();
    final trimmedKey = providerApiKey?.trim();
    if (trimmedKey == null || trimmedKey.isEmpty) {
      logger.error('缺少直连API密钥，无法发起请求');
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

    // 使用适配器构建端点（默认 chat 类型）
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
      return content.toString();
    }

    bool isContentEmpty(dynamic content) {
      if (content == null) return true;
      if (content is String) return content.trim().isEmpty;
      if (content is List) return content.isEmpty;
      return false;
    }

    // 转换历史为 OpenAI Chat 格式（支持 content 为 String 或多模态 List）
    // 支持 role=tool 透传（两回合工具调用场景）
    final chatMessages = <Map<String, dynamic>>[];
    for (final m in messages) {
      final role = (m['role'] ?? '').toString();
      final content = m['content'];

      // role=tool 消息需要完整透传（包含 tool_call_id 等字段）
      if (role == 'tool') {
        chatMessages.add(Map<String, dynamic>.from(m));
        continue;
      }

      // assistant 消息带有 tool_calls 时，即使 content 为空也要保留
      if ((role == 'assistant' || role == 'ai') &&
          m.containsKey('tool_calls')) {
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
      } else if (role == 'assistant' || role == 'ai') {
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
      final contentText = coerceContent(m['content']);
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
      promptPreview = '${promptPreview.substring(0, maxPreviewLength)}…(已截断)';
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

    directTrace.info('发送直连请求', metadata: {
      'messagesCount': chatMessages.length,
      'totalChars': totalChars,
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
            body: jsonEncode(payload),
          )
          .timeout(timeout);
      sw.stop();

      final responseBodyStr = utf8.decode(resp.bodyBytes);

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
          requestBody: ApiLogger.safeSnippet(jsonEncode(payload)),
          responseBody: ApiLogger.safeSnippet(responseBodyStr),
          ok: true,
          // 完整的原始对话数据
          rawContext: jsonEncode(chatMessages),
          rawAiResponse: result.text,
        ));

        directTrace.info('直连响应成功', metadata: {
          'statusCode': resp.statusCode,
          'textLength': result.text.length,
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
        requestBody: ApiLogger.safeSnippet(jsonEncode(payload)),
        responseBody: ApiLogger.safeSnippet(responseBodyStr),
        ok: false,
        rawContext: jsonEncode(chatMessages),
      ));

      // HTTP 错误直接抛出，让上层显示真实原因
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

  /// 流式发送消息（支持分段）- 返回消息块流
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
