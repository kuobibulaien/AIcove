import 'dart:async';
import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config.dart';
import '../api_logger.dart';
import '../app_logger.dart';
import '../utils/content_normalizer.dart';
import 'image_providers/image_provider_adapter.dart';
import 'image_providers/image_provider_adapter_factory.dart';
import 'providers/google_api_mode.dart';
import 'providers/provider_chat_api_path.dart';
import 'providers/provider_adapter_factory.dart';
import 'providers/provider_extra_body.dart';
import 'providers/builtin_web_search_suppressor.dart';
import 'providers/provider_adapter.dart'
    show ProviderAdapter, ProviderChatRequestOptions, ToolCall;
import '../../features/observability/trace_models.dart';
import '../../features/observability/trace_store.dart';

part 'agent_api_direct_chat_support.dart';
part 'agent_api_stream_support.dart';
part 'agent_image_api_support.dart';

class SendMessageRichResult {
  final String text;
  final List<Map<String, dynamic>> toolResults;
  final List<ToolCall> toolCalls; // AI 请求执行的工具调用
  final List<Map<String, dynamic>> hiddenThoughtParts;
  final Map<String, dynamic>? rawResponse; // 原始响应（用于两回合工具调用）

  const SendMessageRichResult({
    required this.text,
    required this.toolResults,
    this.toolCalls = const [],
    this.hiddenThoughtParts = const [],
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
  final http.Client _client;
  final Duration timeout;

  AgentApiClient({http.Client? client, Duration? timeout})
      : _client = client ?? http.Client(),
        timeout = timeout ?? const Duration(seconds: 30);

  _AgentApiDirectChatSupport get _directChatSupport =>
      _AgentApiDirectChatSupport(this);
  _AgentApiStreamSupport get _streamSupport => _AgentApiStreamSupport(this);
  _AgentImageApiSupport get _imageSupport => _AgentImageApiSupport(this);

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
    String? requestId,
    String? requestSource,
    String? flowMode,
  }) {
    return _imageSupport.generateImage(
      provider: provider,
      model: model,
      prompt: prompt,
      negativePrompt: negativePrompt,
      width: width,
      height: height,
      count: count,
      steps: steps,
      guidanceScale: guidanceScale,
      seed: seed,
      sampler: sampler,
      providerApiBase: providerApiBase,
      providerApiKey: providerApiKey,
      customConfig: customConfig,
      requestId: requestId,
      requestSource: requestSource,
      flowMode: flowMode,
    );
  }

  String? _encodeToolCalls(List<ToolCall> toolCalls) {
    if (toolCalls.isEmpty) return null;
    final jsonList = <Map<String, dynamic>>[
      for (final tc in toolCalls)
        {
          'id': tc.id,
          'name': tc.name,
          'arguments': tc.arguments,
          if (tc.thoughtSignature != null)
            'thoughtSignature': tc.thoughtSignature,
        }
    ];
    return jsonEncode(jsonList);
  }

  String _resolveChatEndpoint({
    required ProviderAdapter adapter,
    required String baseUrl,
    required String provider,
    required String model,
    Map<String, dynamic>? customConfig,
    bool streaming = false,
  }) {
    var endpoint = buildProviderChatEndpoint(
      provider: adapter.name,
      apiBaseUrl: baseUrl,
      model: model,
      customConfig: customConfig,
      streaming: streaming,
    );
    if (adapter.name == 'gemini' &&
        streaming &&
        isGoogleGeminiDeveloperApiBaseUrl(baseUrl)) {
      endpoint = _ensureGeminiSseAlt(endpoint);
    }
    return endpoint;
  }

  String _ensureGeminiSseAlt(String endpoint) {
    try {
      final uri = Uri.parse(endpoint);
      if (uri.queryParameters.containsKey('alt')) {
        return endpoint;
      }
      final query = <String, String>{...uri.queryParameters, 'alt': 'sse'};
      return uri.replace(queryParameters: query).toString();
    } catch (_) {
      return endpoint;
    }
  }

  Uri _resolveRequestUri({
    required ProviderAdapter adapter,
    required String endpoint,
    required String apiKey,
    String? baseUrl,
    Map<String, dynamic>? customConfig,
  }) {
    if (adapter.name == 'gemini') {
      return buildGoogleRequestUri(
        endpoint: endpoint,
        vertexExpress: isGoogleAiPlatformPublisherBaseUrl(
          baseUrl ?? endpoint,
        ),
        apiKey: apiKey,
      );
    }
    return Uri.parse(endpoint);
  }

  ({String provider, String model}) _splitModelFullId(String modelFullId) {
    final idx = modelFullId.indexOf(':');
    if (idx <= 0) {
      return (provider: 'openai', model: modelFullId);
    }
    return (
      provider: modelFullId.substring(0, idx),
      model: modelFullId.substring(idx + 1),
    );
  }

  ({
    String provider,
    String model,
    ProviderAdapter adapter,
    String baseUrl,
    String endpoint,
    Uri requestUri,
    String endpointForLogs,
  }) _resolveChatRequestContext({
    required String modelFullId,
    required String providerApiKey,
    String? providerApiBase,
    Map<String, dynamic>? customConfig,
    bool streaming = false,
  }) {
    final parsed = _splitModelFullId(modelFullId);
    final adapter = ProviderAdapterFactory.getAdapter(
      parsed.provider,
      customConfig: customConfig,
      apiBaseUrl: providerApiBase,
    );
    final baseUrl = (providerApiBase == null || providerApiBase.isEmpty)
        ? 'https://api.openai.com/v1'
        : providerApiBase;
    final endpoint = _resolveChatEndpoint(
      adapter: adapter,
      baseUrl: baseUrl,
      provider: parsed.provider,
      model: parsed.model,
      customConfig: customConfig,
      streaming: streaming,
    );
    final requestUri = _resolveRequestUri(
      adapter: adapter,
      endpoint: endpoint,
      apiKey: providerApiKey,
      baseUrl: baseUrl,
      customConfig: customConfig,
    );
    return (
      provider: parsed.provider,
      model: parsed.model,
      adapter: adapter,
      baseUrl: baseUrl,
      endpoint: endpoint,
      requestUri: requestUri,
      endpointForLogs: sanitizeGoogleRequestUrl(requestUri.toString()),
    );
  }

  List<Map<String, dynamic>> _buildChatMessagesForRequest(
    List<Map<String, dynamic>> messages,
    String userText,
  ) {
    final chatMessages = <Map<String, dynamic>>[];
    for (final message in messages) {
      final role = (message['role'] ?? '').toString();
      final content = message['content'];

      if (role == 'tool' || role == 'function') {
        chatMessages.add(Map<String, dynamic>.from(message));
        continue;
      }

      final parts = message['parts'];
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
          (message.containsKey('tool_calls') ||
              message.containsKey('function_call'))) {
        chatMessages.add({
          'role': 'assistant',
          ...Map<String, dynamic>.from(message),
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
    return chatMessages;
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
        text.contains('/v1/messages') ||
        text.contains('/text/chatcompletion_v2');
  }

  Map<String, dynamic>? _buildApiLogRef({
    required String sessionId,
    required String? turnId,
    required int? roundIndex,
    required String eventType,
    required DateTime now,
  }) {
    final normalizedTurnId = turnId?.trim();
    if (normalizedTurnId == null || normalizedTurnId.isEmpty) {
      return null;
    }
    final dateTag =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    return {
      'apiLog': {
        'file': 'api_$dateTag.jsonl',
        'sessionId': sessionId,
        'turnId': normalizedTurnId,
        if (roundIndex != null) 'roundIndex': roundIndex,
        'eventType': eventType,
      },
      'rawFields': const [
        'rawContext',
        'rawRequestBody',
        'rawResponseBody',
        'rawToolCalls',
        'rawToolResults',
        'finalReply',
      ],
    };
  }

  Future<Map<String, dynamic>?> _buildApiPayloadRef({
    required String sessionId,
    required String? turnId,
    required int? roundIndex,
    required String eventType,
    required DateTime now,
    required String? traceId,
    required String stage,
    required Map<String, dynamic> payload,
  }) async {
    final apiLogRef = _buildApiLogRef(
      sessionId: sessionId,
      turnId: turnId,
      roundIndex: roundIndex,
      eventType: eventType,
      now: now,
    );

    final normalizedTraceId = traceId?.trim() ?? '';
    final normalizedTurnId = turnId?.trim() ?? '';
    if (normalizedTraceId.isEmpty || normalizedTurnId.isEmpty) {
      return apiLogRef;
    }

    final compactPayload = _compactPayload(payload);
    if (compactPayload.isEmpty) {
      return apiLogRef;
    }
    final tracePayloadRef = await TraceStore.instance.writePayload(
      traceId: normalizedTraceId,
      sessionId: sessionId,
      turnId: normalizedTurnId,
      roundIndex: roundIndex,
      stage: stage,
      source: 'AgentApiClient',
      payload: compactPayload,
      now: now,
    );
    return _mergePayloadRefs(apiLogRef, tracePayloadRef);
  }

  Map<String, dynamic>? _mergePayloadRefs(
    Map<String, dynamic>? primary,
    Map<String, dynamic>? secondary,
  ) {
    if (primary == null || primary.isEmpty) {
      if (secondary == null || secondary.isEmpty) return null;
      return Map<String, dynamic>.from(secondary);
    }
    if (secondary == null || secondary.isEmpty) {
      return Map<String, dynamic>.from(primary);
    }
    final merged = <String, dynamic>{...primary};
    merged.addAll(secondary);
    return merged;
  }

  Map<String, dynamic> _compactPayload(Map<String, dynamic> payload) {
    final compact = <String, dynamic>{};
    for (final entry in payload.entries) {
      final value = entry.value;
      if (value == null) continue;
      if (value is String && value.trim().isEmpty) continue;
      compact[entry.key] = value;
    }
    return compact;
  }

  _PreparedChatRequest _prepareChatRequest({
    required String modelFullId,
    required List<Map<String, dynamic>> messages,
    required String userText,
    required String providerApiKey,
    double? temperature,
    double? topP,
    String? token,
    String? providerApiBase,
    Map<String, dynamic>? customConfig,
    List<Map<String, dynamic>>? tools,
    ProviderChatRequestOptions? requestOptions,
    bool streaming = false,
    bool allowAuthorizationFallback = false,
  }) {
    final requestContext = _resolveChatRequestContext(
      modelFullId: modelFullId,
      providerApiKey: providerApiKey,
      providerApiBase: providerApiBase,
      customConfig: customConfig,
      streaming: streaming,
    );
    final adapter = requestContext.adapter;
    final chatMessages = _buildChatMessagesForRequest(messages, userText);
    final requestCustomConfig =
        ProviderAdapterFactory.sanitizeRequestCustomConfig(customConfig);
    final payload = adapter.buildRequestBody(
      model: requestContext.model,
      messages: chatMessages,
      temperature: temperature,
      topP: topP,
      customConfig: requestCustomConfig,
      tools: tools,
      requestOptions: requestOptions,
    );
    applyProviderExtraBody(payload, customConfig);
    if (requestOptions?.disableBuiltinWebSearch == true) {
      stripBuiltinWebSearch(payload);
    }
    if (streaming && adapter.name != 'gemini') {
      payload['stream'] = true;
    }

    final requestBodyJson = jsonEncode(payload);
    final headers = _buildChatRequestHeaders(
      adapter: adapter,
      providerApiKey: providerApiKey,
      baseUrl: requestContext.baseUrl,
      customConfig: customConfig,
      token: token,
      streaming: streaming,
      allowAuthorizationFallback: allowAuthorizationFallback,
    );
    final requestDiagnostics = _buildRequestDiagnostics(
      endpoint: requestContext.endpointForLogs,
      provider: requestContext.provider,
      modelFullId: modelFullId,
      model: requestContext.model,
      requestBodyJson: requestBodyJson,
      payload: payload,
      chatMessages: chatMessages,
      customConfig: requestCustomConfig,
      tools: tools,
      providerApiBase: streaming ? providerApiBase : requestContext.baseUrl,
      headers: headers,
    );

    return _PreparedChatRequest(
      provider: requestContext.provider,
      model: requestContext.model,
      adapter: adapter,
      baseUrl: requestContext.baseUrl,
      endpoint: requestContext.endpoint,
      requestUri: requestContext.requestUri,
      endpointForLogs: requestContext.endpointForLogs,
      chatMessages: chatMessages,
      payload: payload,
      requestBodyJson: requestBodyJson,
      headers: headers,
      requestDiagnostics: requestDiagnostics,
    );
  }

  Map<String, String> _buildChatRequestHeaders({
    required ProviderAdapter adapter,
    required String providerApiKey,
    required String baseUrl,
    Map<String, dynamic>? customConfig,
    String? token,
    bool streaming = false,
    bool allowAuthorizationFallback = false,
  }) {
    final headers = <String, String>{
      ...adapter.buildHeaders(providerApiKey),
      if (streaming) 'Accept': 'text/event-stream',
    };
    if (adapter.name == 'gemini' &&
        isGoogleAiPlatformPublisherBaseUrl(baseUrl)) {
      headers.remove('x-goog-api-key');
    }
    if (allowAuthorizationFallback &&
        token != null &&
        token.trim().isNotEmpty &&
        !headers.containsKey('Authorization')) {
      headers['Authorization'] = 'Bearer ${token.trim()}';
    }
    return headers;
  }

  Future<void> _recordRoundRequestBuilt({
    required String? traceId,
    required String sessionId,
    required String? turnId,
    required int roundIndex,
    required String modelFullId,
    required int messagesCount,
    required int toolsCount,
    bool streaming = false,
  }) async {
    if (traceId == null) return;
    await TraceStore.instance.record(
      traceId: traceId,
      sessionId: sessionId,
      turnId: turnId,
      roundIndex: roundIndex,
      stage: TraceStage.roundRequestBuilt,
      source: 'AgentApiClient',
      meta: {
        'modelFullId': modelFullId,
        'messagesCount': messagesCount,
        'toolsCount': toolsCount,
        if (streaming) 'stream': true,
      },
    );
  }

  Future<DateTime> _recordModelRequestSent({
    required String? traceId,
    required String sessionId,
    required String? turnId,
    required int roundIndex,
    required String endpointForLogs,
    required String provider,
    bool streaming = false,
  }) async {
    final requestSentAt = DateTime.now();
    if (traceId == null) return requestSentAt;
    await TraceStore.instance.record(
      traceId: traceId,
      sessionId: sessionId,
      turnId: turnId,
      roundIndex: roundIndex,
      stage: TraceStage.modelRequestSent,
      source: 'AgentApiClient',
      startedAt: requestSentAt,
      endedAt: requestSentAt,
      durationMs: 0,
      meta: {
        'endpoint': endpointForLogs,
        'provider': provider,
        if (streaming) 'stream': true,
      },
    );
    return requestSentAt;
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
    ProviderChatRequestOptions? requestOptions,
    TraceLogger? trace, // 可选的追踪日志器
    String? turnId,
    int? roundIndex,
    String? traceId,
  }) {
    return _directChatSupport.sendMessageRich(
      agentId: agentId,
      sessionId: sessionId,
      modelFullId: modelFullId,
      messages: messages,
      userText: userText,
      temperature: temperature,
      topP: topP,
      token: token,
      toolPrefs: toolPrefs,
      providerApiBase: providerApiBase,
      providerApiKey: providerApiKey,
      customConfig: customConfig,
      tools: tools,
      requestOptions: requestOptions,
      trace: trace,
      turnId: turnId,
      roundIndex: roundIndex,
      traceId: traceId,
    );
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
    ProviderChatRequestOptions? requestOptions,
    void Function(String delta)? onTextDelta,
    void Function()? onToolCallsDetected,
    void Function(List<ToolCall> Function() snapshot)? onToolCallProgress,
    TraceLogger? trace,
    String? turnId,
    int? roundIndex,
    String? traceId,
  }) {
    return _streamSupport.sendMessageRichStream(
      agentId: agentId,
      sessionId: sessionId,
      modelFullId: modelFullId,
      messages: messages,
      userText: userText,
      temperature: temperature,
      topP: topP,
      token: token,
      toolPrefs: toolPrefs,
      providerApiBase: providerApiBase,
      providerApiKey: providerApiKey,
      customConfig: customConfig,
      tools: tools,
      requestOptions: requestOptions,
      onTextDelta: onTextDelta,
      onToolCallsDetected: onToolCallsDetected,
      onToolCallProgress: onToolCallProgress,
      trace: trace,
      turnId: turnId,
      roundIndex: roundIndex,
      traceId: traceId,
    );
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

class _PreparedChatRequest {
  const _PreparedChatRequest({
    required this.provider,
    required this.model,
    required this.adapter,
    required this.baseUrl,
    required this.endpoint,
    required this.requestUri,
    required this.endpointForLogs,
    required this.chatMessages,
    required this.payload,
    required this.requestBodyJson,
    required this.headers,
    required this.requestDiagnostics,
  });

  final String provider;
  final String model;
  final ProviderAdapter adapter;
  final String baseUrl;
  final String endpoint;
  final Uri requestUri;
  final String endpointForLogs;
  final List<Map<String, dynamic>> chatMessages;
  final Map<String, dynamic> payload;
  final String requestBodyJson;
  final Map<String, String> headers;
  final Map<String, dynamic> requestDiagnostics;
}
