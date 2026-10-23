part of 'chat_send_api_runner.dart';

/// Chat-specific policies layered over the shared execution pipeline.
/// Presets, media review, presentation and final delivery do not own a loop.
class _ChatProductStages
    implements
        kernel.ResponseUnpacker,
        kernel.PreToolDecision,
        kernel.PostToolDecision {
  const _ChatProductStages(this.run);
  final _KernelRun run;
  @override
  Future<kernel.AssistantTurn> unpack(
    kernel.AssistantTurn turn,
    kernel.TurnContext ctx,
  ) => run.unpack(turn, ctx);
  @override
  Future<void> beforeTools(
    kernel.AssistantTurn turn,
    kernel.ResolvedToolCalls calls,
    kernel.TurnContext ctx,
  ) => run.beforeTools(turn, calls, ctx);
  @override
  Future<kernel.TurnVerdict> afterTools(
    kernel.AssistantTurn turn,
    kernel.ResolvedToolCalls calls,
    List<kernel.KernelToolResult> results,
    kernel.TurnContext ctx,
  ) => run.afterTools(turn, calls, results, ctx);
}

extension _ChatProductPolicy on _KernelRun {
  // ③ ------------------------------------------------------------------

  Future<kernel.AssistantTurn> unpack(
    kernel.AssistantTurn turn,
    kernel.TurnContext ctx,
  ) async {
    var rich = turn.raw! as SendMessageRichResult;
    var consumedPresetOutput = false;
    final preset = presetRuntime;
    if (preset != null) {
      final response = await preset.response(rich.text, [
        for (final call in rich.toolCalls)
          {
            'id': call.id,
            'name': call.name,
            'arguments': call.arguments,
            if (call.rawArguments != null) 'rawArguments': call.rawArguments,
          },
      ]);
      consumedPresetOutput = response.consumedIndexes.isNotEmpty;
      if (shouldAttemptStreaming) _publishScriptOutput(response.text);
      rich = SendMessageRichResult(
        text: response.text,
        toolResults: rich.toolResults,
        toolCalls: [
          for (var i = 0; i < rich.toolCalls.length; i++)
            if (!response.consumedIndexes.contains(i)) rich.toolCalls[i],
        ],
        hiddenThoughtParts: rich.hiddenThoughtParts,
        rawFinishReason: rich.rawFinishReason,
        reasoning: rich.reasoning,
      );
    }
    lastRich = rich;
    final reasoning = rich.reasoning.trim();
    if (reasoning.isNotEmpty) roundReasonings.add(reasoning);
    roundTrace?.note(
      '响应',
      metadata: {
        'textLength': rich.text.length,
        'toolCalls': rich.toolCalls.length,
      },
    );
    return kernel.AssistantTurn(
      text: rich.text,
      toolCalls: [
        for (final call in rich.toolCalls) _KernelRun._toKernelCall(call),
      ],
      hiddenThoughtParts: rich.hiddenThoughtParts,
      raw: rich,
      presetConsumed: consumedPresetOutput,
      finishReason: rich.finishReason,
    );
  }

  // ⑤ ------------------------------------------------------------------

  Future<void> beforeTools(
    kernel.AssistantTurn turn,
    kernel.ResolvedToolCalls calls,
    kernel.TurnContext ctx,
  ) async {
    final round = ctx.round;
    final currentToolCalls = _KernelRun._toolCallsOf(calls);
    _applyStableReviewDecision(
      assistantText: lastRich!.text,
      toolCalls: currentToolCalls,
      round: round,
    );
    if (currentToolCalls.isEmpty) {
      if (traceContext != null) {
        await TraceStore.instance.record(
          traceId: traceContext!.traceId,
          sessionId: traceContext!.sessionId,
          turnId: traceContext!.turnId,
          roundIndex: round,
          stage: TraceStage.roundCompleted,
          source: 'ChatSendApiRunner',
          meta: {'toolCalls': 0, 'hasToolExecution': false},
        );
      }
      roundTrace?.end(additionalMessage: 'no tool call, stop');
      return;
    }

    if (traceContext != null) {
      await TraceStore.instance.record(
        traceId: traceContext!.traceId,
        sessionId: traceContext!.sessionId,
        turnId: traceContext!.turnId,
        roundIndex: round,
        stage: TraceStage.toolCallDetected,
        source: 'ChatSendApiRunner',
        meta: {
          'count': currentToolCalls.length,
          'names': currentToolCalls.map((t) => t.name).toList(),
          'fallbackParsed': calls.usesFallback,
        },
      );
    }

    final roundNarrativeText = _normalizeRoundNarrativeText(lastRich!.text);
    final keepsNarrative =
        roundNarrativeText.isNotEmpty &&
        !_looksLikeToolInstructionText(roundNarrativeText);
    if (keepsNarrative) {
      preToolNarrativeTexts.add(roundNarrativeText);
    }
    toolRoundDrafts.add((
      narrative: keepsNarrative ? roundNarrativeText : '',
      reasoning: lastRich!.reasoning.trim(),
      toolCallIds: [for (final call in currentToolCalls) call.id],
    ));

    onStreamToolCallObserved?.call();

    useFastToolRoute = _shouldUseFastToolRoute(
      fastModeEnabled: fastImageRouteEnabled,
      toolCalls: currentToolCalls,
    );
    if (fastImageRouteEnabled && !useFastToolRoute) {
      AppLogger.info(
        _KernelRun._logTag,
        '快速生图路由回落常规工具串行执行',
        metadata: {
          'round': round,
          'toolNames': currentToolCalls.map((t) => t.name).toList(),
        },
      );
    }

    toolTrace = roundTrace?.startChild('执行工具调用');
    toolTrace?.note(
      '工具',
      metadata: {
        'count': currentToolCalls.length,
        'names': currentToolCalls.map((t) => t.name).toList(),
        'parallel': useFastToolRoute,
      },
    );
  }

  void _applyStableReviewDecision({
    required String assistantText,
    required List<ToolCall> toolCalls,
    required int round,
  }) {
    if (pendingStableReviewImages.isEmpty) return;

    final wantsToSend = _containsImagePlaceholder(assistantText);
    final requestsRedraw = toolCalls.any((call) => call.name == 'draw_image');

    if (wantsToSend) {
      allToolContents.addAll(pendingStableReviewImages);
      AppLogger.info(
        _KernelRun._logTag,
        'Stable draw_image approved for delivery',
        metadata: {'round': round, 'count': pendingStableReviewImages.length},
      );
      pendingStableReviewImages = <PluginImageContent>[];
      return;
    }

    if (requestsRedraw) {
      AppLogger.info(
        _KernelRun._logTag,
        'Stable draw_image rejected, regenerate',
        metadata: {'round': round},
      );
      pendingStableReviewImages = <PluginImageContent>[];
      return;
    }

    if (toolCalls.isEmpty) {
      AppLogger.info(
        _KernelRun._logTag,
        'Stable draw_image not delivered by model',
        metadata: {'round': round},
      );
      pendingStableReviewImages = <PluginImageContent>[];
    }
  }

  void _collectToolOutcome(_ToolExecutionOutcome outcome, List<ToolResult> to) {
    to.add(outcome.toolResult);
    if (outcome.audioResult != null) {
      allToolAudioResults.add(outcome.audioResult!);
    }
    if (outcome.imageContents.isNotEmpty) {
      if (drawImageStableReviewEnabled &&
          !outcome.isAsyncAcceptedDrawImage &&
          outcome.toolResult.name == 'draw_image') {
        pendingStableReviewImages = _selectStableReviewImages(
          outcome.imageContents,
        );
        AppLogger.info(
          _KernelRun._logTag,
          'Stable draw_image result held for review',
          metadata: {'count': pendingStableReviewImages.length},
        );
      } else {
        allToolContents.addAll(outcome.imageContents);
      }
    }
  }

  // ⑧ ------------------------------------------------------------------

  Future<kernel.TurnVerdict> afterTools(
    kernel.AssistantTurn turn,
    kernel.ResolvedToolCalls calls,
    List<kernel.KernelToolResult> results,
    kernel.TurnContext ctx,
  ) async {
    final round = ctx.round;
    final currentToolCalls = _KernelRun._toolCallsOf(calls);
    final toolOutcomes = [
      for (final result in results) _KernelRun._outcomeOf(result),
    ];
    final toolResults = <ToolResult>[];
    for (final outcome in toolOutcomes) {
      _collectToolOutcome(outcome, toolResults);
    }

    toolTrace?.end();
    executedAnyTool = true;
    allToolCalls.addAll(currentToolCalls);
    allRawToolResults.addAll([
      for (final r in toolResults)
        ToolResult(
          toolCallId: r.toolCallId,
          name: r.name,
          result: r.persistentText,
          isError: r.isError,
          structured: r.structured,
        ),
    ]);
    final encodedToolCalls = _encodeToolCallsForLog(currentToolCalls);
    final encodedToolResults = _encodeToolResultsForLog(toolResults);
    Map<String, dynamic>? toolPayloadRef;
    int? toolEventSeq;
    if (traceContext != null) {
      toolPayloadRef = await TraceStore.instance.writePayload(
        traceId: traceContext!.traceId,
        sessionId: traceContext!.sessionId,
        turnId: traceContext!.turnId,
        roundIndex: round,
        stage: TraceStage.toolExecFinished.value,
        source: 'ChatSendApiRunner',
        payload: {
          'rawToolCalls': encodedToolCalls,
          'rawToolResults': encodedToolResults,
        },
      );
      final toolTraceEvent = await TraceStore.instance.record(
        traceId: traceContext!.traceId,
        sessionId: traceContext!.sessionId,
        turnId: traceContext!.turnId,
        roundIndex: round,
        stage: TraceStage.toolExecFinished,
        source: 'ChatSendApiRunner',
        payloadRef: toolPayloadRef,
        meta: {
          'toolCalls': currentToolCalls.length,
          'toolResults': toolResults.length,
          'aggregated': true,
        },
      );
      toolEventSeq = toolTraceEvent.eventSeq;
    }
    ApiLogger.add(
      ApiLogEntry(
        time: DateTime.now(),
        method: 'TOOL',
        url: 'local://chat/tools',
        status: 200,
        durationMs: 0,
        requestBody: '',
        responseBody: '',
        ok: true,
        sessionId: sessionId,
        turnId: effectiveTurnId,
        roundIndex: round,
        eventType: 'tool_execution',
        rawToolCalls: encodedToolCalls,
        rawToolResults: encodedToolResults,
        stage: TraceStage.toolExecFinished.value,
        stageStatus: TraceEventStatus.success.value,
        source: 'ChatSendApiRunner',
        eventSeq: toolEventSeq,
        payloadRef: toolPayloadRef,
      ),
    );
    if (traceContext != null) {
      await TraceStore.instance.record(
        traceId: traceContext!.traceId,
        sessionId: traceContext!.sessionId,
        turnId: traceContext!.turnId,
        roundIndex: round,
        stage: TraceStage.roundCompleted,
        source: 'ChatSendApiRunner',
        meta: {
          'toolCalls': currentToolCalls.length,
          'toolResults': toolResults.length,
          'hasToolExecution': true,
        },
      );
    }

    if (turn.finishReason == kernel.FinishReason.length)
      return const kernel.TurnVerdict.proceed();

    final shouldContinueFastFollowup =
        useFastToolRoute && toolOutcomes.any((o) => o.isAsyncAcceptedDrawImage);

    if (useFastToolRoute && !shouldContinueFastFollowup) {
      AppLogger.info(
        _KernelRun._logTag,
        '快速生图路由停止后续模型轮次',
        metadata: {'round': round},
      );
      roundTrace?.end(additionalMessage: 'fast mode stop');
      return const kernel.TurnVerdict.stop(
        kernel.KernelStopReason.fastModeStop,
      );
    }

    return const kernel.TurnVerdict.proceed();
  }

  // Result processing (outside the loop, inside the runner) ---------------

  Future<ApiCallResult> finalize({
    ApiRunStatus status = ApiRunStatus.completed,
    List<Map<String, dynamic>> runningMessages = const [],
    String? stopReason,
  }) async {
    var rawAssistantText = lastRich?.text ?? '';
    var finalAssistantText = rawAssistantText;
    final normalizedFinalText = _normalizeRoundNarrativeText(
      finalAssistantText,
    );
    if (preToolNarrativeTexts.isNotEmpty) {
      final rawMergedTexts = <String>[...preToolNarrativeTexts];
      final trimmedRawAssistantText = rawAssistantText.trim();
      if (trimmedRawAssistantText.isNotEmpty &&
          !_looksLikeToolInstructionText(trimmedRawAssistantText)) {
        rawMergedTexts.add(rawAssistantText);
      }
      rawAssistantText = _mergeNarrativeTexts(rawMergedTexts);
      final mergedTexts = <String>[...preToolNarrativeTexts];
      if (normalizedFinalText.isNotEmpty &&
          !_looksLikeToolInstructionText(normalizedFinalText)) {
        mergedTexts.add(normalizedFinalText);
      }
      finalAssistantText = _mergeNarrativeTexts(mergedTexts);
    } else {
      finalAssistantText = normalizedFinalText;
    }
    final generatedImageCount = allToolContents
        .whereType<PluginImageContent>()
        .length;
    if (executedAnyTool &&
        (finalAssistantText.trim().isEmpty ||
            _looksLikeToolInstructionText(finalAssistantText))) {
      finalAssistantText = _buildToolCompletionSummary(
        generatedImageCount: generatedImageCount,
        hasAudio: allToolAudioResults.isNotEmpty,
      );
    }
    finalAssistantText = _sanitizeAssistantText(finalAssistantText);
    if (generatedImageCount > 0) {
      finalAssistantText = _stripStandaloneImagePlaceholders(
        finalAssistantText,
      );
    }
    if (executedAnyTool && finalAssistantText.trim().isEmpty) {
      finalAssistantText = _buildToolCompletionSummary(
        generatedImageCount: generatedImageCount,
        hasAudio: allToolAudioResults.isNotEmpty,
      );
    }
    // 调过工具时按轮拆开：每轮话术单独过正则和插件，展示时与工具调用交替。
    final roundTexts = !executedAnyTool || toolRoundDrafts.isEmpty
        ? null
        : _replyRoundTexts(
            narratives: [for (final draft in toolRoundDrafts) draft.narrative],
            normalizedFinalText: normalizedFinalText,
            mergedText: finalAssistantText,
          );
    final roundRegexResults = await _applyRoundRegex(
      roundTexts ?? [finalAssistantText],
      config,
    );
    final presetRegexResult = _joinRegexResults(roundRegexResults);
    finalAssistantText = presetRegexResult.text;
    apiCallTrace?.note(
      '完成',
      metadata: {
        'textLength': finalAssistantText.length,
        'toolResults': lastRich?.toolResults.length ?? 0,
      },
    );
    apiCallTrace?.end(additionalMessage: status.name);
    final pluginTrace = _trace?.startChild('运行插件');
    final roundPluginResults = await _runRoundProcessors(
      roundRegexResults,
      responseProcessors,
    );
    final pluginResult = _joinPluginResults(roundPluginResults);
    pluginTrace?.note(
      '插件处理',
      metadata: {
        'original': finalAssistantText.length,
        'processed': pluginResult.processedText.length,
        'events': pluginResult.events.length,
      },
    );
    pluginTrace?.end();
    Map<String, dynamic>? finalPayloadRef;
    int? finalEventSeq;
    if (traceContext != null) {
      finalPayloadRef = await TraceStore.instance.writePayload(
        traceId: traceContext!.traceId,
        sessionId: traceContext!.sessionId,
        turnId: traceContext!.turnId,
        roundIndex: lastRoundIndex,
        stage: TraceStage.finalReplyReady.value,
        source: 'ChatSendApiRunner',
        payload: {
          'rawAiResponse': rawAssistantText,
          'regexDisplayText': finalAssistantText,
          'regex': <String, dynamic>{
            'declared': config.presetRegexScripts.length,
            'authorized': config.presetRegexAuthorized,
            'warnings': presetRegexResult.warnings,
            'trace': presetRegexResult.traces,
          },
          'finalReply': pluginResult.processedText,
        },
      );
      final traceEvent = await TraceStore.instance.record(
        traceId: traceContext!.traceId,
        sessionId: traceContext!.sessionId,
        turnId: traceContext!.turnId,
        roundIndex: lastRoundIndex,
        stage: TraceStage.finalReplyReady,
        source: 'ChatSendApiRunner',
        payloadRef: finalPayloadRef,
        meta: {
          'status': status.name,
          'stopReason': stopReason,
          'rawReplyLength': rawAssistantText.length,
          'finalReplyLength': pluginResult.processedText.length,
        },
      );
      finalEventSeq = traceEvent.eventSeq;
    }
    ApiLogger.add(
      ApiLogEntry(
        time: DateTime.now(),
        method: 'DELIVER',
        url: 'local://chat/final_reply',
        status: 200,
        durationMs: 0,
        requestBody: '',
        responseBody: '',
        ok: true,
        sessionId: sessionId,
        turnId: effectiveTurnId,
        roundIndex: lastRoundIndex,
        eventType: 'final_response',
        rawAiResponse: rawAssistantText,
        finalReply: pluginResult.processedText,
        stage: TraceStage.finalReplyReady.value,
        stageStatus: TraceEventStatus.success.value,
        source: 'ChatSendApiRunner',
        eventSeq: finalEventSeq,
        payloadRef: finalPayloadRef,
      ),
    );
    final allEvents = [...allToolEvents, ...pluginResult.events];
    final allContents = [...allToolContents, ...pluginResult.contents];
    final displayCandidate = pluginResult.processedText.trim().isNotEmpty
        ? pluginResult.processedText
        : finalAssistantText;
    final shouldSuppressStatusText = _shouldSuppressToolStatusText(
      text: displayCandidate,
      generatedImageCount: generatedImageCount,
      hasAudio: allToolAudioResults.isNotEmpty,
      toolCallCount: allToolCalls.length,
    );

    return ApiCallResult(
      status: status,
      runningMessages: runningMessages,
      stopReason: stopReason,
      lastModelText: lastRich?.text,
      rawReplyText: rawAssistantText,
      replyText: shouldSuppressStatusText ? '' : finalAssistantText,
      processedText: shouldSuppressStatusText ? '' : pluginResult.processedText,
      hiddenThoughtParts: lastRich?.hiddenThoughtParts ?? const [],
      pluginEvents: allEvents,
      pluginContents: allContents,
      toolResults: lastRich?.toolResults ?? [],
      toolAudioResults: allToolAudioResults,
      toolCalls: allToolCalls,
      rawToolResults: allRawToolResults,
      reasoning: joinRoundReasonings(roundReasonings),
      replyRounds: roundTexts == null
          ? const []
          : [
              for (var i = 0; i < roundTexts.length; i++)
                _replyRound(
                  index: i,
                  regexText: roundRegexResults[i].text,
                  pluginResult: roundPluginResults[i],
                  suppressText: shouldSuppressStatusText,
                ),
            ],
    );
  }

  ReplyRound _replyRound({
    required int index,
    required String regexText,
    required PluginProcessResult pluginResult,
    required bool suppressText,
  }) {
    final isFinal = index == toolRoundDrafts.length;
    return ReplyRound(
      replyText: suppressText ? '' : regexText,
      processedText: suppressText ? '' : pluginResult.processedText,
      pluginEvents: [if (isFinal) ...allToolEvents, ...pluginResult.events],
      pluginContents: [
        if (isFinal) ...allToolContents,
        ...pluginResult.contents,
      ],
      // 最后一次模型调用本身是工具轮（达到轮次上限、快速生图停轮）时，
      // 它的思考已记在那一轮，正文轮不再重复。
      reasoning: !isFinal
          ? toolRoundDrafts[index].reasoning
          : toolRoundDrafts.length >= lastRoundIndex
          ? ''
          : (lastRich?.reasoning.trim() ?? ''),
      toolCallIds: isFinal ? const [] : toolRoundDrafts[index].toolCallIds,
    );
  }
}
