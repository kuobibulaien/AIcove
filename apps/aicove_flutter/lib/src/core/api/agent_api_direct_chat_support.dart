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
    String? providerApiBase,
    String? providerApiKey,
    Map<String, dynamic>? customConfig,
    List<Map<String, dynamic>>? tools,
    ProviderChatRequestOptions? requestOptions,
    TraceLogger? trace,
    String? turnId,
    int? roundIndex,
    String? traceId,
  }) async {
    final logger = trace ??
        AppLogger.startTrace('API调用',
            source: 'AgentApiClient', traceId: traceId);

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
      requestOptions: requestOptions,
    );
    final provider = preparedRequest.provider;
    final model = preparedRequest.model;
    final adapter = preparedRequest.adapter;
    final endpoint = preparedRequest.endpoint;
    final requestUri = preparedRequest.requestUri;
    final endpointForLogs = preparedRequest.endpointForLogs;
    final chatMessages = preparedRequest.chatMessages;
    final payload = preparedRequest.payload;
    final logRequestBodyJson = preparedRequest.logRequestBodyJson;
    final logContextJson = preparedRequest.logContextJson;
    final headers = preparedRequest.headers;
    final requestDiagnostics = preparedRequest.requestDiagnostics;

    final directTrace = logger.startChild('直连请求');
    directTrace.info('直连目标地址', metadata: {
      'endpoint': endpointForLogs,
      'model': modelFullId,
      'hasCustomConfig': customConfig != null,
    });

    final promptPreview = _buildPromptPreview(preparedRequest.logChatMessages);
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

    final sw = Stopwatch();
    final receivedBytes = <int>[];
    int? responseStatus;
    TokenUsage? usage;
    var usageRecorded = false;
    DateTime? requestSentAt;
    Future<void> recordUsage({
      String output = '',
      String reasoning = '',
      List<ToolCall> calls = const [],
    }) async {
      if (usageRecorded ||
          responseStatus == null ||
          responseStatus < 200 ||
          responseStatus >= 300) {
        return;
      }
      usage ??= TokenUsage.estimate(
        messages: chatMessages,
        tools: tools,
        outputText: output,
        reasoningText: reasoning,
        toolCalls: calls,
      );
      await TokenUsageLedger.instance.recordHttpRound(
        requestId:
            '${traceId ?? turnId ?? sessionId}:$round:${requestSentAt!.microsecondsSinceEpoch}',
        providerId: provider,
        model: model,
        usage: usage!,
        occurredAt: requestSentAt,
        conversationId:
            TokenUsageCaptureScope.current?.conversationId ?? sessionId,
        turnId: turnId,
        roundIndex: roundIndex,
        durationMs: sw.elapsedMilliseconds,
      );
      usageRecorded = true;
    }

    var traceResponseRecorded = false;
    var apiLogRecorded = false;
    try {
      requestSentAt = await _owner._recordModelRequestSent(
        traceId: traceId,
        sessionId: sessionId,
        turnId: turnId,
        roundIndex: round,
        endpointForLogs: endpointForLogs,
        provider: provider,
      );

      sw.start();
      final request = RequestControl.request('POST', requestUri)
        ..headers.addAll(headers)
        ..bodyBytes = preparedRequest.requestBodyBytes;
      final streamedResponse = await modelTransportRequest(
        () => _client.send(request).timeout(timeout),
      );
      responseStatus = streamedResponse.statusCode;
      final resp = await modelTransportRequest(
        () => http.Response.fromStream(
          http.StreamedResponse(
            modelTransportStream(streamedResponse.stream.timeout(timeout)).map((chunk) {
              receivedBytes.addAll(chunk);
              return chunk;
            }),
            streamedResponse.statusCode,
            headers: streamedResponse.headers,
          ),
        ).timeout(timeout),
      );
      sw.stop();

      final responseBodyStr = utf8.decode(resp.bodyBytes);

      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final data = jsonDecode(responseBodyStr) as Map<String, dynamic>;
        usage = _parseHttpUsage(adapter.name, data);
        final result = adapter.parseResponse(data);
        await recordUsage(
          output: result.text,
          reasoning: result.reasoning,
          calls: result.toolCalls,
        );
        final payloadRef = await _owner._buildApiPayloadRef(
          sessionId: sessionId,
          turnId: turnId,
          roundIndex: roundIndex,
          eventType: 'round',
          now: DateTime.now(),
          traceId: traceId,
          stage: TraceStage.modelResponseReceived.value,
          payload: {
            'rawContext': logContextJson,
            'rawRequestBody': logRequestBodyJson,
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
              ..._usageMetadata(usage),
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
          requestBody: preparedRequest.requestBodySnippet,
          responseBody: ApiLogger.safeSnippet(responseBodyStr),
          ok: true,
          inputTokens: usage?.inputTokens,
          outputTokens: usage?.outputTokens,
          cachedInputTokens: usage?.cachedInputTokens,
          cacheWriteTokens: usage?.cacheWriteTokens,
          reasoningTokens: usage?.reasoningTokens,
          usageEstimated: usage?.isEstimated,
          rawContext: logContextJson,
          rawAiResponse: result.text,
          rawRequestBody: logRequestBodyJson,
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
          usage: usage,
          toolResults: result.toolResults,
          toolCalls: result.toolCalls,
          hiddenThoughtParts: result.hiddenThoughtParts,
          rawResponse: result.rawResponse,
          rawFinishReason: result.rawFinishReason,
          reasoning: result.reasoning,
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
          'rawContext': logContextJson,
          'rawRequestBody': logRequestBodyJson,
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
        requestBody: preparedRequest.requestBodySnippet,
        responseBody: ApiLogger.safeSnippet(responseBodyStr),
        ok: false,
        rawContext: logContextJson,
        rawRequestBody: logRequestBodyJson,
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
      throw modelRequestFailure(ModelHttpException(resp.statusCode, resp.body,
        retryAfter: ModelHttpException.parseRetryAfter(resp.headers['retry-after'])));
    } catch (e) {
      sw.stop();
      // A 2xx response may be truncated before a complete JSON body arrives.
      final partialBody = utf8.decode(receivedBytes, allowMalformed: true);
      final partialText =
          RegExp(
            r'"(?:content|text|output_text)"\s*:\s*"((?:\\.|[^"\\])*)',
          ).allMatches(partialBody).map((match) => match.group(1) ?? '').join();
      await recordUsage(output: partialText);
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
            'rawContext': logContextJson,
            'rawRequestBody': logRequestBodyJson,
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
          meta: {'error': e.toString(), ..._usageMetadata(usage)},
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
            'rawContext': logContextJson,
            'rawRequestBody': logRequestBodyJson,
            'error': e.toString(),
          },
        );
        ApiLogger.add(ApiLogEntry(
          time: DateTime.now(),
          method: 'POST',
          url: endpoint,
          status: responseStatus,
          durationMs: sw.elapsedMilliseconds,
          inputTokens: usage?.inputTokens,
          outputTokens: usage?.outputTokens,
          cachedInputTokens: usage?.cachedInputTokens,
          cacheWriteTokens: usage?.cacheWriteTokens,
          reasoningTokens: usage?.reasoningTokens,
          usageEstimated: usage?.isEstimated,
          requestBody: preparedRequest.requestBodySnippet,
          responseBody: ApiLogger.safeSnippet(e.toString()),
          ok: false,
          rawContext: logContextJson,
          rawRequestBody: logRequestBodyJson,
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
        requestBodyBytes: preparedRequest.requestBodyBytes.length,
        requestBodyPreview: requestDiagnostics['requestBodyPreview'] as String,
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
