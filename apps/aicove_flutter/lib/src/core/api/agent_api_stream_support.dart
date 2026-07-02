part of 'agent_api.dart';

class _AgentApiStreamSupport {
  const _AgentApiStreamSupport(this._owner);

  static const int _maxStoredStreamEventsDebug = 360;
  static const int _maxStoredStreamEventsRelease = 120;

  final AgentApiClient _owner;

  http.Client get _client => _owner._client;
  Duration get timeout => _owner.timeout;

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
    String? traceId,
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
      streaming: true,
      allowAuthorizationFallback: true,
    );
    final provider = preparedRequest.provider;
    final adapter = preparedRequest.adapter;
    final adapterName = adapter.name;
    final isOpenAiStream = adapterName == 'openai' || adapterName == 'minimax';
    final isGeminiStream = adapterName == 'gemini';
    final isClaudeStream = adapterName == 'claude';
    if (!isOpenAiStream && !isGeminiStream && !isClaudeStream) {
      directTrace.error('provider stream unsupported', metadata: {
        'provider': provider,
        'adapter': adapterName,
      });
      directTrace.end(additionalMessage: '直连流式失败');
      if (trace == null) {
        logger.end(additionalMessage: '直连流式调用失败');
      }
      throw UnsupportedError(
        'Streaming is only supported for OpenAI-compatible, Gemini, and Claude providers',
      );
    }

    final endpoint = preparedRequest.endpoint;
    final requestUri = preparedRequest.requestUri;
    final endpointForLogs = preparedRequest.endpointForLogs;
    final chatMessages = preparedRequest.chatMessages;
    final requestBodyJson = preparedRequest.requestBodyJson;
    final headers = preparedRequest.headers;
    final requestDiagnostics = preparedRequest.requestDiagnostics;
    final round = roundIndex ?? 0;

    await _owner._recordRoundRequestBuilt(
      traceId: traceId,
      sessionId: sessionId,
      turnId: turnId,
      roundIndex: round,
      modelFullId: modelFullId,
      messagesCount: chatMessages.length,
      toolsCount: tools?.length ?? 0,
      streaming: true,
    );

    directTrace.info('发送直连流式请求', metadata: {
      'endpoint': endpointForLogs,
      'model': modelFullId,
      'messagesCount': chatMessages.length,
      'hasTools': tools != null && tools.isNotEmpty,
      'toolsCount': tools?.length ?? 0,
    });

    final sw = Stopwatch()..start();
    final request = http.Request('POST', requestUri);
    request.headers.addAll(headers);
    request.body = requestBodyJson;
    final requestSentAt = await _owner._recordModelRequestSent(
      traceId: traceId,
      sessionId: sessionId,
      turnId: turnId,
      roundIndex: round,
      endpointForLogs: endpointForLogs,
      provider: provider,
      streaming: true,
    );

    var traceResponseRecorded = false;
    var apiLogRecorded = false;
    try {
      final response = await _client.send(request).timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final errBody = utf8.decode(await response.stream.toBytes());
        sw.stop();
        final payloadRef = await _owner._buildApiPayloadRef(
          sessionId: sessionId,
          turnId: turnId,
          roundIndex: roundIndex,
          eventType: 'round_stream',
          now: DateTime.now(),
          traceId: traceId,
          stage: TraceStage.modelStreamAggregated.value,
          payload: {
            'rawContext': jsonEncode(chatMessages),
            'rawRequestBody': requestBodyJson,
            'rawResponseBody': errBody,
          },
        );
        int? traceEventSeq;
        if (traceId != null) {
          final traceEvent = await TraceStore.instance.record(
            traceId: traceId,
            sessionId: sessionId,
            turnId: turnId,
            roundIndex: round,
            stage: TraceStage.modelStreamAggregated,
            status: TraceEventStatus.failed,
            source: 'AgentApiClient',
            startedAt: requestSentAt,
            endedAt: DateTime.now(),
            durationMs: sw.elapsedMilliseconds,
            payloadRef: payloadRef,
            meta: {
              'statusCode': response.statusCode,
              'responseSnippet': ApiLogger.safeSnippet(errBody, max: 800),
            },
          );
          traceEventSeq = traceEvent.eventSeq;
          traceResponseRecorded = true;
        }
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
          stage: TraceStage.modelStreamAggregated.value,
          stageStatus: TraceEventStatus.failed.value,
          source: 'AgentApiClient',
          eventSeq: traceEventSeq,
          payloadRef: payloadRef,
        ));
        apiLogRecorded = true;
        directTrace.error('直连流式请求失败(非2xx)', metadata: {
          'statusCode': response.statusCode,
          'responseBody': ApiLogger.safeSnippet(errBody, max: 2000),
          ...requestDiagnostics,
        });
        throw Exception('HTTP ${response.statusCode}: $errBody');
      }

      final responseContentType =
          response.headers['content-type']?.toLowerCase() ?? '';
      final usesGeminiJsonBody = isGeminiStream &&
          responseContentType.contains('application/json') &&
          !responseContentType.contains('text/event-stream');

      final text = StringBuffer();
      final reasoning = StringBuffer();
      final toolAggregator = _StreamingToolCallAggregator();
      final anthropicToolAggregator = _AnthropicStreamingToolUseAggregator();
      final geminiToolAggregator = _GeminiStreamingFunctionCallAggregator();
      final geminiThoughtAggregator = _GeminiStreamingThoughtPartAggregator();
      final textDeltaNormalizer = _StreamingTextDeltaNormalizer();
      var done = false;
      var toolCallsObserved = false;
      final dataLines = <String>[];
      final rawStreamEvents = <Object?>[];
      final streamEventStats = <String, int>{'total': 0, 'dropped': 0};

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

      void consumeGeminiCandidate(Map<String, dynamic> candidate) {
        final rawContent = candidate['content'];
        if (rawContent is! Map) return;
        final content =
            Map<String, dynamic>.from(rawContent.cast<String, dynamic>());
        final rawParts = content['parts'];
        if (rawParts is! List) return;
        for (final rawPart in rawParts) {
          if (rawPart is! Map) continue;
          final part =
              Map<String, dynamic>.from(rawPart.cast<String, dynamic>());
          final isThoughtPart = _isGeminiThoughtPart(part);
          if (isThoughtPart) {
            geminiThoughtAggregator.consumePart(part);
          }
          final textPart = _extractStreamingText(part['text']);
          if (!isThoughtPart && textPart.isNotEmpty) {
            emitTextDelta(textPart);
          }
          final rawFunctionCall = part['functionCall'] ?? part['function_call'];
          if (rawFunctionCall is Map) {
            final functionCall = Map<String, dynamic>.from(
              rawFunctionCall.cast<String, dynamic>(),
            );
            geminiToolAggregator.consumeFunctionCall(
              functionCall,
              thoughtSignature: part['thoughtSignature']?.toString() ??
                  part['thought_signature']?.toString(),
            );
            markToolCallsObserved();
          }
        }
      }

      void handleDecodedEventMap(Map<String, dynamic> evt) {
        final rootError = evt['error'];
        if (rootError != null) {
          final message = rootError is Map
              ? rootError['message']?.toString() ??
                  jsonEncode(Map<String, dynamic>.from(
                    rootError.cast<String, dynamic>(),
                  ))
              : rootError.toString();
          throw Exception('SSE error: $message');
        }

        if (isClaudeStream) {
          final eventType = evt['type']?.toString() ?? '';
          anthropicToolAggregator.consumeEvent(evt);
          if (anthropicToolAggregator.hasToolUse) {
            markToolCallsObserved();
          }

          if (eventType == 'content_block_delta') {
            final rawDelta = evt['delta'];
            if (rawDelta is Map) {
              final delta =
                  Map<String, dynamic>.from(rawDelta.cast<String, dynamic>());
              final deltaType = delta['type']?.toString() ?? '';
              if (deltaType == 'text_delta') {
                final textDelta = _extractStreamingText(delta['text']);
                if (textDelta.isNotEmpty) {
                  emitTextDelta(textDelta);
                }
              } else if (deltaType == 'thinking_delta') {
                final reasoningDelta = _extractStreamingText(delta['thinking']);
                if (reasoningDelta.isNotEmpty) {
                  emitReasoningDelta(reasoningDelta);
                }
              }
            }
          } else if (eventType == 'error') {
            final error = evt['error'];
            final message = error is Map
                ? error['message']?.toString() ?? 'unknown stream error'
                : 'unknown stream error';
            throw Exception('SSE error: $message');
          } else if (eventType == 'message_stop') {
            done = true;
          }
          return;
        }

        if (isGeminiStream) {
          var geminiConsumed = false;
          final candidates = evt['candidates'];
          if (candidates is List && candidates.isNotEmpty) {
            geminiConsumed = true;
            for (final rawCandidate in candidates) {
              if (rawCandidate is! Map) continue;
              final candidate = Map<String, dynamic>.from(
                  rawCandidate.cast<String, dynamic>());
              consumeGeminiCandidate(candidate);
            }
          }

          final rawFunctionCall = evt['functionCall'] ?? evt['function_call'];
          if (rawFunctionCall is Map) {
            geminiConsumed = true;
            final functionCall = Map<String, dynamic>.from(
              rawFunctionCall.cast<String, dynamic>(),
            );
            geminiToolAggregator.consumeFunctionCall(
              functionCall,
              thoughtSignature: evt['thoughtSignature']?.toString() ??
                  evt['thought_signature']?.toString(),
            );
            markToolCallsObserved();
          }

          if (geminiConsumed) {
            return;
          }
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

        consumeToolCalls(evt['tool_calls']);
        consumeLegacyFunctionCall(evt['function_call']);
        final rootReasoningContent =
            _extractStreamingText(evt['reasoning_content']);
        if (rootReasoningContent.isNotEmpty) {
          emitReasoningDelta(rootReasoningContent);
        }

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

      void handleEventPayload(String payload) {
        final trimmed = payload.trim();
        if (trimmed.isEmpty) return;
        if (trimmed == '[DONE]') {
          _appendStreamEvent(
            rawStreamEvents,
            '[DONE]',
            stats: streamEventStats,
            preserveOnOverflow: true,
          );
          done = true;
          return;
        }

        dynamic decoded;
        try {
          decoded = jsonDecode(trimmed);
          _appendStreamEvent(rawStreamEvents, decoded, stats: streamEventStats);
        } catch (_) {
          _appendStreamEvent(
            rawStreamEvents,
            {
              '_raw': trimmed,
              '_parseError': true,
            },
            stats: streamEventStats,
          );
          return;
        }

        if (decoded is Map) {
          handleDecodedEventMap(
            Map<String, dynamic>.from(decoded.cast<String, dynamic>()),
          );
          return;
        }

        if (decoded is List) {
          for (final item in decoded) {
            if (item is! Map) continue;
            handleDecodedEventMap(
              Map<String, dynamic>.from(item.cast<String, dynamic>()),
            );
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

      if (usesGeminiJsonBody) {
        final rawBody = utf8.decode(await response.stream.toBytes());
        handleEventPayload(rawBody);
      } else {
        await for (final line in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
          if (done) break;
          if (line.isEmpty) {
            flushEvent();
            continue;
          }
          if (line.startsWith(':')) continue;
          if (line.startsWith('event:')) continue;
          if (line.startsWith('data:')) {
            dataLines.add(line.substring(5).trimLeft());
            continue;
          }
          final trimmedLine = line.trimLeft();
          if (trimmedLine.startsWith('{') || trimmedLine.startsWith('[')) {
            dataLines.add(trimmedLine);
            continue;
          }
        }
        flushEvent();
      }

      sw.stop();
      final builtToolCalls = switch (adapterName) {
        'claude' => anthropicToolAggregator.build(),
        'gemini' => geminiToolAggregator.build(),
        _ => toolAggregator.build(),
      };
      final finalText = text.toString();
      final finalReasoning = reasoning.toString();
      final hiddenThoughtParts = switch (adapterName) {
        'gemini' => geminiThoughtAggregator.build(),
        _ => const <Map<String, dynamic>>[],
      };
      final synthesizedRawResponse = switch (adapterName) {
        'claude' => _buildAnthropicStreamRawResponse(
            text: finalText,
            toolCalls: builtToolCalls,
          ),
        'gemini' => _buildGeminiStreamRawResponse(
            text: finalText,
            toolCalls: builtToolCalls,
            hiddenThoughtParts: hiddenThoughtParts,
          ),
        _ => _buildOpenAiStreamRawResponse(
            text: finalText,
            reasoning: finalReasoning,
            toolCalls: builtToolCalls,
          ),
      };
      final streamStats = _buildStreamEventStats(
        rawStreamEvents,
        streamEventStats,
      );
      final rawResponseBodyForLog = jsonEncode({
        'streamEvents': rawStreamEvents,
        if (streamStats != null) 'streamEventStats': streamStats,
      });
      final payloadRef = await _owner._buildApiPayloadRef(
        sessionId: sessionId,
        turnId: turnId,
        roundIndex: roundIndex,
        eventType: 'round_stream',
        now: DateTime.now(),
        traceId: traceId,
        stage: TraceStage.modelStreamAggregated.value,
        payload: {
          'rawContext': jsonEncode(chatMessages),
          'rawRequestBody': requestBodyJson,
          'rawResponseBody': rawResponseBodyForLog,
          'rawToolCalls': _owner._encodeToolCalls(builtToolCalls),
        },
      );
      int? traceEventSeq;
      if (traceId != null) {
        final traceEvent = await TraceStore.instance.record(
          traceId: traceId,
          sessionId: sessionId,
          turnId: turnId,
          roundIndex: round,
          stage: TraceStage.modelStreamAggregated,
          source: 'AgentApiClient',
          startedAt: requestSentAt,
          endedAt: DateTime.now(),
          durationMs: sw.elapsedMilliseconds,
          payloadRef: payloadRef,
          meta: {
            'statusCode': response.statusCode,
            'toolCalls': builtToolCalls.length,
            'textLength': finalText.length,
          },
        );
        traceEventSeq = traceEvent.eventSeq;
        traceResponseRecorded = true;
      }
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
        rawToolCalls: _owner._encodeToolCalls(builtToolCalls),
        sessionId: sessionId,
        turnId: turnId,
        roundIndex: roundIndex,
        eventType: 'round_stream',
        stage: TraceStage.modelStreamAggregated.value,
        stageStatus: TraceEventStatus.success.value,
        source: 'AgentApiClient',
        eventSeq: traceEventSeq,
        payloadRef: payloadRef,
      ));
      apiLogRecorded = true;

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
        hiddenThoughtParts: hiddenThoughtParts,
        rawResponse: synthesizedRawResponse,
      );
    } catch (e) {
      sw.stop();
      Map<String, dynamic>? catchPayloadRef;
      int? catchTraceEventSeq;
      if (traceId != null && !traceResponseRecorded) {
        catchPayloadRef = await _owner._buildApiPayloadRef(
          sessionId: sessionId,
          turnId: turnId,
          roundIndex: roundIndex,
          eventType: 'round_stream',
          now: DateTime.now(),
          traceId: traceId,
          stage: TraceStage.modelStreamAggregated.value,
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
          roundIndex: round,
          stage: TraceStage.modelStreamAggregated,
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
          eventType: 'round_stream',
          now: DateTime.now(),
          traceId: traceId,
          stage: TraceStage.modelStreamAggregated.value,
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
          durationMs: sw.elapsedMilliseconds,
          requestBody: ApiLogger.safeSnippet(requestBodyJson),
          responseBody: ApiLogger.safeSnippet(e.toString()),
          ok: false,
          rawContext: jsonEncode(chatMessages),
          rawRequestBody: requestBodyJson,
          rawResponseBody: jsonEncode({'error': e.toString()}),
          sessionId: sessionId,
          turnId: turnId,
          roundIndex: roundIndex,
          eventType: 'round_stream',
          stage: TraceStage.modelStreamAggregated.value,
          stageStatus: TraceEventStatus.failed.value,
          source: 'AgentApiClient',
          eventSeq: catchTraceEventSeq,
          payloadRef: catchPayloadRef,
        ));
        apiLogRecorded = true;
      }
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

  int _maxStoredStreamEvents() =>
      kDebugMode ? _maxStoredStreamEventsDebug : _maxStoredStreamEventsRelease;

  void _appendStreamEvent(
    List<Object?> events,
    Object? event, {
    required Map<String, int> stats,
    bool preserveOnOverflow = false,
  }) {
    stats['total'] = (stats['total'] ?? 0) + 1;
    final maxEvents = _maxStoredStreamEvents();
    if (events.length >= maxEvents) {
      stats['dropped'] = (stats['dropped'] ?? 0) + 1;
      if (preserveOnOverflow && events.isNotEmpty) {
        events[events.length - 1] = event;
      }
      return;
    }
    events.add(event);
  }

  Map<String, dynamic>? _buildStreamEventStats(
    List<Object?> events,
    Map<String, int> stats,
  ) {
    final total = stats['total'] ?? events.length;
    final dropped = stats['dropped'] ?? 0;
    if (dropped <= 0 && total <= events.length) return null;
    return <String, dynamic>{
      'total': total,
      'captured': events.length,
      'dropped': dropped,
      'maxCaptured': _maxStoredStreamEvents(),
    };
  }

  Map<String, dynamic> _buildOpenAiStreamRawResponse({
    required String text,
    required String reasoning,
    required List<ToolCall> toolCalls,
  }) {
    final assistantMessage = <String, dynamic>{
      'role': 'assistant',
      'content': text.isEmpty ? null : text,
      if (reasoning.isNotEmpty) 'reasoning_content': reasoning,
      if (toolCalls.isNotEmpty)
        'tool_calls': [
          for (final call in toolCalls) call.toOpenAIFormat(),
        ],
    };
    return <String, dynamic>{
      'choices': [
        {'message': assistantMessage}
      ],
    };
  }

  Map<String, dynamic> _buildGeminiStreamRawResponse({
    required String text,
    required List<ToolCall> toolCalls,
    required List<Map<String, dynamic>> hiddenThoughtParts,
  }) {
    final parts = <Map<String, dynamic>>[
      for (final part in hiddenThoughtParts) Map<String, dynamic>.from(part),
    ];
    if (text.isNotEmpty) {
      parts.add({'text': text});
    }
    for (final call in toolCalls) {
      final functionCall = <String, dynamic>{
        'name': call.name,
        'args': call.arguments,
      };
      final id = call.id.trim();
      if (id.isNotEmpty) {
        functionCall['id'] = id;
      }
      parts.add({
        'functionCall': functionCall,
        if (call.thoughtSignature != null)
          'thoughtSignature': call.thoughtSignature,
      });
    }
    return <String, dynamic>{
      'candidates': [
        {
          'content': {
            'role': 'model',
            'parts': parts,
          },
        }
      ],
    };
  }

  Map<String, dynamic> _buildAnthropicStreamRawResponse({
    required String text,
    required List<ToolCall> toolCalls,
  }) {
    final content = <Map<String, dynamic>>[];
    if (text.isNotEmpty) {
      content.add({
        'type': 'text',
        'text': text,
      });
    }
    for (var i = 0; i < toolCalls.length; i++) {
      final call = toolCalls[i];
      final id = call.id.trim().isEmpty ? 'toolu_stream_${i + 1}' : call.id;
      content.add({
        'type': 'tool_use',
        'id': id,
        'name': call.name,
        'input': call.arguments,
      });
    }
    return <String, dynamic>{
      'role': 'assistant',
      'content': content,
    };
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

class _AnthropicStreamingToolUseAggregator {
  final Map<int, _AnthropicStreamingToolUseState> _statesByIndex = {};

  bool get hasToolUse => _statesByIndex.isNotEmpty;

  void consumeEvent(Map<String, dynamic> event) {
    final type = event['type']?.toString() ?? '';
    if (type == 'content_block_start') {
      final index = (event['index'] as num?)?.toInt();
      final rawBlock = event['content_block'];
      if (index == null || rawBlock is! Map) return;
      final block = Map<String, dynamic>.from(rawBlock.cast<String, dynamic>());
      if (block['type']?.toString() != 'tool_use') return;
      final state = _statesByIndex.putIfAbsent(
        index,
        _AnthropicStreamingToolUseState.new,
      );
      state.consumeStart(block);
      return;
    }

    if (type == 'content_block_delta') {
      final index = (event['index'] as num?)?.toInt();
      final rawDelta = event['delta'];
      if (index == null || rawDelta is! Map) return;
      final delta = Map<String, dynamic>.from(rawDelta.cast<String, dynamic>());
      if (delta['type']?.toString() != 'input_json_delta') return;
      final state = _statesByIndex.putIfAbsent(
        index,
        _AnthropicStreamingToolUseState.new,
      );
      final partial = delta['partial_json']?.toString() ?? '';
      state.appendPartialJson(partial);
    }
  }

  List<ToolCall> build() {
    final results = <ToolCall>[];
    final indices = _statesByIndex.keys.toList()..sort();
    for (final index in indices) {
      final state = _statesByIndex[index];
      if (state == null || !state.hasToolName) continue;
      results.add(state.toToolCall(index));
    }
    return results;
  }
}

class _AnthropicStreamingToolUseState {
  String _id = '';
  String _name = '';
  Map<String, dynamic>? _seedInput;
  final StringBuffer _partialJson = StringBuffer();

  bool get hasToolName => _name.trim().isNotEmpty;

  void consumeStart(Map<String, dynamic> block) {
    final id = block['id']?.toString().trim() ?? '';
    if (id.isNotEmpty) {
      _id = id;
    }
    final name = block['name']?.toString().trim() ?? '';
    if (name.isNotEmpty) {
      _name = name;
    }
    final rawInput = block['input'];
    if (rawInput is Map) {
      _seedInput = Map<String, dynamic>.from(rawInput.cast<String, dynamic>());
    }
  }

  void appendPartialJson(String partial) {
    if (partial.isEmpty) return;
    _partialJson.write(partial);
  }

  ToolCall toToolCall(int index) {
    final rawPartial = _partialJson.toString().trim();
    final parsedArgs =
        _parseJsonObject(rawPartial) ?? _seedInput ?? <String, dynamic>{};
    final id = _id.trim().isNotEmpty ? _id : 'toolu_stream_${index + 1}';
    return ToolCall(
      id: id,
      name: _name,
      arguments: parsedArgs,
    );
  }

  Map<String, dynamic>? _parseJsonObject(String raw) {
    if (raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.map(
          (key, value) => MapEntry(key.toString(), value),
        );
      }
    } catch (_) {
      return <String, dynamic>{'_raw': raw};
    }
    return null;
  }
}

class _GeminiStreamingFunctionCallAggregator {
  final List<ToolCall> _calls = <ToolCall>[];
  final Map<String, int> _callIndexBySignature = <String, int>{};

  void consumeFunctionCall(
    Map<String, dynamic> rawCall, {
    String? thoughtSignature,
  }) {
    final name = rawCall['name']?.toString().trim() ??
        rawCall['functionName']?.toString().trim() ??
        '';
    if (name.isEmpty) return;

    final arguments = _parseArguments(rawCall['args'] ?? rawCall['arguments']);
    final id = rawCall['id']?.toString().trim() ?? '';
    final callKey = '$name:${jsonEncode(arguments)}';
    final existingIndex = _callIndexBySignature[callKey];
    if (existingIndex != null) {
      final existing = _calls[existingIndex];
      _calls[existingIndex] = ToolCall(
        id: existing.id.isNotEmpty ? existing.id : id,
        name: existing.name,
        arguments: existing.arguments,
        thoughtSignature: existing.thoughtSignature ?? thoughtSignature,
      );
      return;
    }

    _callIndexBySignature[callKey] = _calls.length;
    _calls.add(
      ToolCall(
        id: id.isNotEmpty ? id : 'gemini_tool_call_${_calls.length + 1}',
        name: name,
        arguments: arguments,
        thoughtSignature: thoughtSignature,
      ),
    );
  }

  List<ToolCall> build() => List<ToolCall>.from(_calls);

  Map<String, dynamic> _parseArguments(dynamic rawArgs) {
    if (rawArgs is Map<String, dynamic>) {
      return Map<String, dynamic>.from(rawArgs);
    }
    if (rawArgs is Map) {
      return rawArgs.map(
        (key, value) => MapEntry(key.toString(), value),
      );
    }
    if (rawArgs is String && rawArgs.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(rawArgs);
        if (decoded is Map<String, dynamic>) {
          return decoded;
        }
        if (decoded is Map) {
          return decoded.map(
            (key, value) => MapEntry(key.toString(), value),
          );
        }
      } catch (_) {
        return <String, dynamic>{'_raw': rawArgs};
      }
    }
    return <String, dynamic>{};
  }
}

class _GeminiStreamingThoughtPartAggregator {
  final List<Map<String, dynamic>> _parts = <Map<String, dynamic>>[];

  void consumePart(Map<String, dynamic> rawPart) {
    if (!_isGeminiThoughtPart(rawPart)) return;
    final part = Map<String, dynamic>.from(rawPart);
    if (_parts.isNotEmpty && _canMergeTrailingTextPart(_parts.last, part)) {
      final previousText = (_parts.last['text'] ?? '').toString();
      final nextText = (part['text'] ?? '').toString();
      _parts.last['text'] = '$previousText$nextText';
      return;
    }
    _parts.add(part);
  }

  List<Map<String, dynamic>> build() => <Map<String, dynamic>>[
        for (final part in _parts) Map<String, dynamic>.from(part),
      ];

  bool _canMergeTrailingTextPart(
    Map<String, dynamic> previous,
    Map<String, dynamic> next,
  ) {
    if (previous['text'] is! String || next['text'] is! String) {
      return false;
    }
    if (previous.containsKey('functionCall') ||
        previous.containsKey('function_call') ||
        next.containsKey('functionCall') ||
        next.containsKey('function_call')) {
      return false;
    }

    final previousKeys = previous.keys.toSet();
    final nextKeys = next.keys.toSet();
    if (previousKeys.length != nextKeys.length ||
        !previousKeys.containsAll(nextKeys)) {
      return false;
    }

    for (final key in previousKeys) {
      if (key == 'text') continue;
      if (previous[key] != next[key]) return false;
    }
    return true;
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

    if (incoming.startsWith(_fullText)) {
      final suffix = incoming.substring(_fullText.length);
      _fullText = incoming;
      return suffix;
    }

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

bool _isGeminiThoughtPart(Map<String, dynamic> part) {
  final thought = part['thought'];
  if (thought is bool) return thought;
  return thought?.toString().trim().toLowerCase() == 'true';
}
