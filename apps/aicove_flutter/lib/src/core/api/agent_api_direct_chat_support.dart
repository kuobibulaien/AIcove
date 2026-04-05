part of 'agent_api.dart';

class _AgentApiDirectChatSupport {
  const _AgentApiDirectChatSupport(this._owner);

  final AgentApiClient _owner;

  http.Client get _client => _owner._client;
  Duration get timeout => _owner.timeout;

  Future<SendMessageRichResult> sendMessageRich({
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
    TraceLogger? trace,
    String? turnId,
    int? roundIndex,
    String? traceId,
  }) async {
    final logger =
        trace ?? AppLogger.startTrace('API调用', source: 'AgentApiClient');

    final trimmedBase = providerApiBase?.trim();
    final trimmedKey = providerApiKey?.trim();
    if (trimmedKey == null || trimmedKey.isEmpty) {
      logger.error('Missing providerApiKey for direct call');
      if (trace == null) {
        logger.end(additionalMessage: '直连调用失败');
      }
      throw StateError('Missing providerApiKey for direct call');
    }

    final preparedRequest = _owner._prepareChatRequest(
      modelFullId: modelFullId,
      messages: messages,
      userText: userText,
      providerApiKey: trimmedKey,
      temperature: temperature,
      topP: topP,
      token: token,
      providerApiBase: trimmedBase,
      customConfig: customConfig,
      tools: tools,
    );
    final provider = preparedRequest.provider;
    final model = preparedRequest.model;
    final adapter = preparedRequest.adapter;
    final endpoint = preparedRequest.endpoint;
    final requestUri = preparedRequest.requestUri;
    final endpointForLogs = preparedRequest.endpointForLogs;
    final chatMessages = preparedRequest.chatMessages;
    final payload = preparedRequest.payload;
    final requestBodyJson = preparedRequest.requestBodyJson;
    final headers = preparedRequest.headers;
    final requestDiagnostics = preparedRequest.requestDiagnostics;

    final directTrace = logger.startChild('直连请求');
    directTrace.info('直连目标地址', metadata: {
      'endpoint': endpointForLogs,
      'model': modelFullId,
      'hasCustomConfig': customConfig != null,
    });

    final promptPreview = _buildPromptPreview(chatMessages);
    final totalChars = promptPreview.totalChars;
    final round = roundIndex ?? 0;

    await _owner._recordRoundRequestBuilt(
      traceId: traceId,
      sessionId: sessionId,
      turnId: turnId,
      roundIndex: round,
      modelFullId: modelFullId,
      messagesCount: chatMessages.length,
      toolsCount: tools?.length ?? 0,
    );

    directTrace.info('发送直连请求', metadata: {
      'messagesCount': chatMessages.length,
      'totalChars': totalChars,
      'hasTools': tools != null && tools.isNotEmpty,
      'toolsCount': tools?.length ?? 0,
      'userText':
          userText.length > 50 ? '${userText.substring(0, 50)}...' : userText,
      'promptPreview': promptPreview.preview,
    });

    var traceResponseRecorded = false;
    var apiLogRecorded = false;
    try {
      final requestSentAt = await _owner._recordModelRequestSent(
        traceId: traceId,
        sessionId: sessionId,
        turnId: turnId,
        roundIndex: round,
        endpointForLogs: endpointForLogs,
        provider: provider,
      );

      final sw = Stopwatch()..start();
      final resp = await _client
          .post(
            requestUri,
            headers: headers,
            body: requestBodyJson,
          )
          .timeout(timeout);
      sw.stop();

      final responseBodyStr = utf8.decode(resp.bodyBytes);

      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final data = jsonDecode(responseBodyStr) as Map<String, dynamic>;
        final result = adapter.parseResponse(data);
        final payloadRef = await _owner._buildApiPayloadRef(
          sessionId: sessionId,
          turnId: turnId,
          roundIndex: roundIndex,
          eventType: 'round',
          now: DateTime.now(),
          traceId: traceId,
          stage: TraceStage.modelResponseReceived.value,
          payload: {
            'rawContext': jsonEncode(chatMessages),
            'rawRequestBody': requestBodyJson,
            'rawResponseBody': responseBodyStr,
            'rawToolCalls': _owner._encodeToolCalls(result.toolCalls),
          },
        );
        int? traceEventSeq;
        if (traceId != null) {
          final traceEvent = await TraceStore.instance.record(
            traceId: traceId,
            sessionId: sessionId,
            turnId: turnId,
            roundIndex: round,
            stage: TraceStage.modelResponseReceived,
            source: 'AgentApiClient',
            startedAt: requestSentAt,
            endedAt: DateTime.now(),
            durationMs: sw.elapsedMilliseconds,
            payloadRef: payloadRef,
            meta: {
              'statusCode': resp.statusCode,
              'toolCalls': result.toolCalls.length,
              'textLength': result.text.length,
            },
          );
          traceEventSeq = traceEvent.eventSeq;
          traceResponseRecorded = true;
        }

        ApiLogger.add(ApiLogEntry(
          time: DateTime.now(),
          method: 'POST',
          url: endpoint,
          status: resp.statusCode,
          durationMs: sw.elapsedMilliseconds,
          requestBody: ApiLogger.safeSnippet(requestBodyJson),
          responseBody: ApiLogger.safeSnippet(responseBodyStr),
          ok: true,
          rawContext: jsonEncode(chatMessages),
          rawAiResponse: result.text,
          rawRequestBody: requestBodyJson,
          rawResponseBody: responseBodyStr,
          rawToolCalls: _owner._encodeToolCalls(result.toolCalls),
          sessionId: sessionId,
          turnId: turnId,
          roundIndex: roundIndex,
          eventType: 'round',
          stage: TraceStage.modelResponseReceived.value,
          stageStatus: TraceEventStatus.success.value,
          source: 'AgentApiClient',
          eventSeq: traceEventSeq,
          payloadRef: payloadRef,
        ));
        apiLogRecorded = true;

        directTrace.info('直连响应成功', metadata: {
          'statusCode': resp.statusCode,
          'textLength': result.text.length,
          'toolCalls': result.toolCalls.length,
          'text': result.text.length > 100
              ? '${result.text.substring(0, 100)}...'
              : result.text,
        });
        directTrace.end(additionalMessage: '直连调用完成');
        if (trace == null) logger.end();

        return SendMessageRichResult(
          text: result.text,
          toolResults: result.toolResults,
          toolCalls: result.toolCalls,
          hiddenThoughtParts: result.hiddenThoughtParts,
          rawResponse: result.rawResponse,
        );
      }

      final payloadRef = await _owner._buildApiPayloadRef(
        sessionId: sessionId,
        turnId: turnId,
        roundIndex: roundIndex,
        eventType: 'round',
        now: DateTime.now(),
        traceId: traceId,
        stage: TraceStage.modelResponseReceived.value,
        payload: {
          'rawContext': jsonEncode(chatMessages),
          'rawRequestBody': requestBodyJson,
          'rawResponseBody': responseBodyStr,
        },
      );
      int? traceEventSeq;
      if (traceId != null) {
        final traceEvent = await TraceStore.instance.record(
          traceId: traceId,
          sessionId: sessionId,
          turnId: turnId,
          roundIndex: round,
          stage: TraceStage.modelResponseReceived,
          status: TraceEventStatus.failed,
          source: 'AgentApiClient',
          startedAt: requestSentAt,
          endedAt: DateTime.now(),
          durationMs: sw.elapsedMilliseconds,
          payloadRef: payloadRef,
          meta: {
            'statusCode': resp.statusCode,
            'responseSnippet': ApiLogger.safeSnippet(responseBodyStr, max: 800),
          },
        );
        traceEventSeq = traceEvent.eventSeq;
        traceResponseRecorded = true;
      }
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
        stage: TraceStage.modelResponseReceived.value,
        stageStatus: TraceEventStatus.failed.value,
        source: 'AgentApiClient',
        eventSeq: traceEventSeq,
        payloadRef: payloadRef,
      ));
      apiLogRecorded = true;

      directTrace.error('直连请求失败', metadata: {
        'statusCode': resp.statusCode,
        'responseBody': ApiLogger.safeSnippet(responseBodyStr, max: 2000),
        ...requestDiagnostics,
      });
      throw Exception('HTTP ${resp.statusCode}: ${resp.body}');
    } catch (e) {
      Map<String, dynamic>? catchPayloadRef;
      int? catchTraceEventSeq;
      if (traceId != null && !traceResponseRecorded) {
        catchPayloadRef = await _owner._buildApiPayloadRef(
          sessionId: sessionId,
          turnId: turnId,
          roundIndex: roundIndex,
          eventType: 'round',
          now: DateTime.now(),
          traceId: traceId,
          stage: TraceStage.modelResponseReceived.value,
          payload: {
            'rawContext': jsonEncode(chatMessages),
            'rawRequestBody': requestBodyJson,
            'error': e.toString(),
          },
        );
        final traceEvent = await TraceStore.instance.record(
          traceId: traceId,
          sessionId: sessionId,
          turnId: turnId,
          roundIndex: roundIndex ?? 0,
          stage: TraceStage.modelResponseReceived,
          status: TraceEventStatus.failed,
          source: 'AgentApiClient',
          payloadRef: catchPayloadRef,
          meta: {'error': e.toString()},
        );
        catchTraceEventSeq = traceEvent.eventSeq;
        traceResponseRecorded = true;
      }
      if (!apiLogRecorded) {
        catchPayloadRef ??= await _owner._buildApiPayloadRef(
          sessionId: sessionId,
          turnId: turnId,
          roundIndex: roundIndex,
          eventType: 'round',
          now: DateTime.now(),
          traceId: traceId,
          stage: TraceStage.modelResponseReceived.value,
          payload: {
            'rawContext': jsonEncode(chatMessages),
            'rawRequestBody': requestBodyJson,
            'error': e.toString(),
          },
        );
        ApiLogger.add(ApiLogEntry(
          time: DateTime.now(),
          method: 'POST',
          url: endpoint,
          status: null,
          durationMs: 0,
          requestBody: ApiLogger.safeSnippet(requestBodyJson),
          responseBody: ApiLogger.safeSnippet(e.toString()),
          ok: false,
          rawContext: jsonEncode(chatMessages),
          rawRequestBody: requestBodyJson,
          rawResponseBody: jsonEncode({'error': e.toString()}),
          sessionId: sessionId,
          turnId: turnId,
          roundIndex: roundIndex,
          eventType: 'round',
          stage: TraceStage.modelResponseReceived.value,
          stageStatus: TraceEventStatus.failed.value,
          source: 'AgentApiClient',
          eventSeq: catchTraceEventSeq,
          payloadRef: catchPayloadRef,
        ));
        apiLogRecorded = true;
      }
      final catchRequestDiagnostics = _owner._buildRequestDiagnostics(
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
        ...catchRequestDiagnostics,
      });
      directTrace.end(additionalMessage: '直连失败');
      if (trace == null) {
        logger.end(additionalMessage: '直连调用失败');
      }
      rethrow;
    }
  }

  _PromptPreview _buildPromptPreview(List<Map<String, dynamic>> chatMessages) {
    var totalChars = 0;
    const maxPreviewLength = 100;
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
    var preview = previewBuffer.toString();
    if (preview.length > maxPreviewLength) {
      preview = '${preview.substring(0, maxPreviewLength)}...(已截断)';
    }
    return _PromptPreview(
      totalChars: totalChars,
      preview: preview,
    );
  }
}

class _PromptPreview {
  const _PromptPreview({
    required this.totalChars,
    required this.preview,
  });

  final int totalChars;
  final String preview;
}
