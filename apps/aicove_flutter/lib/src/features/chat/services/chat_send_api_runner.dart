library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../plugins/domain/handlers/ai_tool.dart';
import '../../plugins/domain/plugin.dart';
import '../../plugins/domain/plugin_content.dart';
import '../../../core/api/agent_api.dart';
import '../../../core/api/providers/provider_adapter.dart'
    show ToolCall, ToolResult;
import '../../../core/api/providers/provider_adapter_factory.dart';
import '../../../core/api_logger.dart';
import '../../../core/app_logger.dart';
import '../../../core/utils/mime_utils.dart';
import '../../settings/settings_models.dart';
import '../../observability/trace_models.dart';
import '../../observability/trace_store.dart';
import 'chat_request_message_builder.dart';
import 'chat_tool_fallback_parser.dart';
import 'chat_types.dart';
import 'stream_monitor_service.dart';

part 'chat_send_api_runner_tool_support.dart';
part 'chat_send_api_runner_text_support.dart';

typedef _AgentClientFactory = AgentApiClient Function(Duration timeout);

/// API 调用与工具循环执行器。
///
/// 将 ChatSendService 中最复杂的“模型调用 -> 工具执行 -> 回写工具结果 -> 再调用”
/// 主循环独立出来，降低服务类体积并隔离高风险逻辑。
class ChatSendApiRunner {
  const ChatSendApiRunner() : _agentClientFactory = _defaultAgentClientFactory;

  ChatSendApiRunner.withAgentClientFactory({
    required AgentApiClient Function(Duration timeout) agentClientFactory,
  }) : _agentClientFactory = agentClientFactory;

  static const ChatToolFallbackParser _fallbackParser =
      ChatToolFallbackParser();
  static const String _logTag = 'ChatSendService';
  static const int _maxFastFollowupRounds = 1;
  static const String _stableDrawImageReviewPrefix =
      '__AICOVE_DRAW_IMAGE_REVIEW__';
  static const String _stableDrawImageReviewInstruction =
      '$_stableDrawImageReviewPrefix以下图片是你刚刚通过 draw_image 生成的候选图，尚未发给用户。'
      '请先检查图片内容是否符合用户要求。若图片画得不好、肢体有错误、结构异常，或明显不符合需求，'
      '你可以调整提示词后再次调用 draw_image 返工。只有当你决定把这张图发给用户时，才在正文里输出空标签 <image></image>；'
      '如果暂时不要发，就不要输出占位符。';
  static final RegExp _imagePlaceholderRegex = RegExp(
    r'(?:<image>\s*</image>|\[(?:图片|image)(?:\s*:[^\]]*)?\])',
    caseSensitive: false,
  );
  static AgentApiClient _defaultAgentClientFactory(Duration timeout) =>
      AgentApiClient(timeout: timeout);

  final _AgentClientFactory _agentClientFactory;

  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    required List<Plugin> effectivePlugins,
    List<AITool>? availableTools,
    String? turnId,
    TraceLogger? trace,
    int maxRounds = 5,
    void Function(String toolName)? onToolExecuting,
    bool enableStreaming = false,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
    TraceContext? traceContext,
  }) async {
    final flowSettings = config.settings.callFlowSettings;
    final effectiveImageRoute =
        config.settings.resolveEffectiveImageGenerationRoute(
      config.modelFullId,
    );
    final stableImageRouteEnabled =
        effectiveImageRoute == EffectiveImageGenerationRoute.stable;
    final fastImageRouteEnabled =
        effectiveImageRoute == EffectiveImageGenerationRoute.fast;
    final modelTimeout = Duration(seconds: flowSettings.modelTimeoutSeconds);
    final toolTimeout = Duration(seconds: flowSettings.toolTimeoutSeconds);
    final supportsVision = config.settings.hasChatModelCapability(
      config.modelFullId,
      ChatModelCapability.vision,
    );
    final drawImageStableReviewEnabled = stableImageRouteEnabled;

    final apiCallTrace = trace?.startChild('调用AI API');
    apiCallTrace?.note('连接', metadata: {
      'endpoint':
          config.providerApiBase.isNotEmpty ? config.providerApiBase : '后端网关',
      'model': config.modelFullId,
      'history': config.messages.length,
      'mode': flowSettings.mode.value,
      'effectiveImageRoute': effectiveImageRoute.value,
      'maxRounds': maxRounds,
      'fastFollowupBudget': fastImageRouteEnabled ? _maxFastFollowupRounds : 0,
      'modelTimeoutSec': flowSettings.modelTimeoutSeconds,
      'toolTimeoutSec': flowSettings.toolTimeoutSeconds,
    });
    final effectiveTurnId = (turnId != null && turnId.trim().isNotEmpty)
        ? turnId.trim()
        : 'turn_${DateTime.now().microsecondsSinceEpoch}';

    final agent = _agentClientFactory(modelTimeout);
    final allToolEvents = <PluginEvent>[];
    final allToolAudioResults = <ToolAudioResult>[];
    final allToolContents = <PluginContent>[];

    String provider = 'openai';
    final idx = config.modelFullId.indexOf(':');
    if (idx > 0) {
      provider = config.modelFullId.substring(0, idx);
    }
    final adapter = ProviderAdapterFactory.getAdapter(
      provider,
      customConfig: config.customConfig,
      apiBaseUrl: config.providerApiBase,
    );
    const supportsTextToolFallback = true;

    var currentMessages = List<Map<String, dynamic>>.from(config.messages);
    SendMessageRichResult? lastRich;
    var shouldAttemptStreaming = enableStreaming;
    final executedFallbackCallSignatures = <String>{};
    var executedAnyTool = false;
    var lastRoundIndex = 1;
    final preToolNarrativeTexts = <String>[];
    var remainingFastFollowupRounds =
        fastImageRouteEnabled ? _maxFastFollowupRounds : 0;

    final allToolCalls = <ToolCall>[];
    final allRawToolResults = <ToolResult>[];
    var pendingStableReviewImages = <PluginImageContent>[];

    void collectToolOutcome(
        _ToolExecutionOutcome outcome, List<ToolResult> to) {
      to.add(outcome.toolResult);
      if (outcome.audioResult != null) {
        allToolAudioResults.add(outcome.audioResult!);
      }
      if (outcome.imageContents.isNotEmpty) {
        if (drawImageStableReviewEnabled &&
            !outcome.isAsyncAcceptedDrawImage &&
            outcome.toolResult.name == 'draw_image') {
          pendingStableReviewImages =
              _selectStableReviewImages(outcome.imageContents);
          AppLogger.info(_logTag, 'Stable draw_image result held for review',
              metadata: {
                'count': pendingStableReviewImages.length,
              });
        } else {
          allToolContents.addAll(outcome.imageContents);
        }
      }
    }

    void applyStableReviewDecision({
      required String assistantText,
      required List<ToolCall> toolCalls,
      required int round,
    }) {
      if (pendingStableReviewImages.isEmpty) return;

      final wantsToSend = _containsImagePlaceholder(assistantText);
      final requestsRedraw = toolCalls.any((call) => call.name == 'draw_image');

      if (wantsToSend) {
        allToolContents.addAll(pendingStableReviewImages);
        AppLogger.info(_logTag, 'Stable draw_image approved for delivery',
            metadata: {
              'round': round,
              'count': pendingStableReviewImages.length,
            });
        pendingStableReviewImages = <PluginImageContent>[];
        return;
      }

      if (requestsRedraw) {
        AppLogger.info(_logTag, 'Stable draw_image rejected, regenerate',
            metadata: {
              'round': round,
            });
        pendingStableReviewImages = <PluginImageContent>[];
        return;
      }

      if (toolCalls.isEmpty) {
        AppLogger.info(_logTag, 'Stable draw_image not delivered by model',
            metadata: {
              'round': round,
            });
        pendingStableReviewImages = <PluginImageContent>[];
      }
    }

    for (var round = 1; round <= maxRounds; round++) {
      if (!supportsVision) {
        currentMessages = _sanitizeMessagesForNonVisionModel(currentMessages);
      }
      lastRoundIndex = round;
      final roundTrace = apiCallTrace?.startChild('第 $round 轮 API 调用');
      roundTrace?.note('请求', metadata: {
        'round': round,
        'mode': flowSettings.mode.value,
        'messagesCount': currentMessages.length,
      });

      Future<SendMessageRichResult> sendRichNonStream() =>
          agent.sendMessageRich(
            agentId: 'default',
            sessionId: sessionId,
            modelFullId: config.modelFullId,
            messages: currentMessages,
            userText: round == 1 ? (userText ?? '') : '',
            temperature: config.effectiveTemperature,
            topP: config.modelTopP,
            token: config.settings.backendApiKey,
            toolPrefs: config.toolPrefs,
            providerApiBase: config.providerApiBase,
            providerApiKey: config.providerApiKey,
            customConfig: config.customConfig,
            tools: config.tools,
            trace: roundTrace,
            turnId: effectiveTurnId,
            roundIndex: round,
            traceId: traceContext?.traceId,
          );

      if (shouldAttemptStreaming) {
        final streamTextFilter = _VisibleAssistantStreamFilter();
        unawaited(StreamMonitorService.recordAttempt(
          modelFullId: config.modelFullId,
          round: round,
        ));
        try {
          lastRich = await agent.sendMessageRichStream(
            agentId: 'default',
            sessionId: sessionId,
            modelFullId: config.modelFullId,
            messages: currentMessages,
            userText: round == 1 ? (userText ?? '') : '',
            temperature: config.effectiveTemperature,
            topP: config.modelTopP,
            token: config.settings.backendApiKey,
            toolPrefs: config.toolPrefs,
            providerApiBase: config.providerApiBase,
            providerApiKey: config.providerApiKey,
            customConfig: config.customConfig,
            tools: config.tools,
            onTextDelta: (delta) {
              if (onStreamTextDelta == null || delta.isEmpty) return;
              final visibleDelta = streamTextFilter.consume(delta);
              if (visibleDelta.isEmpty) return;
              onStreamTextDelta(visibleDelta);
            },
            onToolCallsDetected: onStreamToolCallObserved,
            trace: roundTrace,
            turnId: effectiveTurnId,
            roundIndex: round,
            traceId: traceContext?.traceId,
          );
          unawaited(StreamMonitorService.recordSuccess(
            modelFullId: config.modelFullId,
            round: round,
          ));
        } catch (e) {
          shouldAttemptStreaming = false;
          onStreamingFallback?.call();
          final failureReason = StreamMonitorService.classifyError(e);
          unawaited(StreamMonitorService.recordFallback(
            modelFullId: config.modelFullId,
            error: e,
            reason: failureReason,
            round: round,
          ));
          AppLogger.warning(_logTag, '流式调用失败，回退整段响应', metadata: {
            'round': round,
            'model': config.modelFullId,
            'reason': failureReason.value,
            'error': e.toString(),
          });
          lastRich = await sendRichNonStream();
        }
      } else {
        lastRich = await sendRichNonStream();
      }

      roundTrace?.note('响应', metadata: {
        'textLength': lastRich.text.length,
        'toolCalls': lastRich.toolCalls.length,
      });

      var currentToolCalls = List<ToolCall>.from(lastRich.toolCalls);
      var usesFallbackToolCalls = false;
      if (currentToolCalls.isEmpty && supportsTextToolFallback) {
        final fallbackToolCalls = _extractFallbackToolCalls(lastRich.text);
        if (fallbackToolCalls.isNotEmpty) {
          final deduped = <ToolCall>[];
          for (final call in fallbackToolCalls) {
            final signature = _buildToolCallSignature(call);
            if (executedFallbackCallSignatures.contains(signature)) {
              continue;
            }
            executedFallbackCallSignatures.add(signature);
            deduped.add(call);
          }
          if (deduped.isNotEmpty) {
            currentToolCalls = deduped;
            usesFallbackToolCalls = true;
            AppLogger.info(_logTag, 'Parsed text tool call fallback',
                metadata: {
                  'round': round,
                  'count': deduped.length,
                  'names': deduped.map((t) => t.name).toList(),
                });
          } else {
            AppLogger.warning(
              _logTag,
              'Duplicate fallback tool call skipped',
              metadata: {'round': round},
            );
          }
        }
      }
      applyStableReviewDecision(
        assistantText: lastRich.text,
        toolCalls: currentToolCalls,
        round: round,
      );
      if (currentToolCalls.isEmpty) {
        if (traceContext != null) {
          await TraceStore.instance.record(
            traceId: traceContext.traceId,
            sessionId: traceContext.sessionId,
            turnId: traceContext.turnId,
            roundIndex: round,
            stage: TraceStage.roundCompleted,
            source: 'ChatSendApiRunner',
            meta: {'toolCalls': 0, 'hasToolExecution': false},
          );
        }
        roundTrace?.end(additionalMessage: 'no tool call, stop');
        break;
      }

      if (traceContext != null) {
        await TraceStore.instance.record(
          traceId: traceContext.traceId,
          sessionId: traceContext.sessionId,
          turnId: traceContext.turnId,
          roundIndex: round,
          stage: TraceStage.toolCallDetected,
          source: 'ChatSendApiRunner',
          meta: {
            'count': currentToolCalls.length,
            'names': currentToolCalls.map((t) => t.name).toList(),
            'fallbackParsed': usesFallbackToolCalls,
          },
        );
      }

      final roundNarrativeText = _normalizeRoundNarrativeText(lastRich.text);
      if (roundNarrativeText.isNotEmpty &&
          !_looksLikeToolInstructionText(roundNarrativeText)) {
        preToolNarrativeTexts.add(roundNarrativeText);
      }

      onStreamToolCallObserved?.call();

      final useFastToolRoute = _shouldUseFastToolRoute(
        fastModeEnabled: fastImageRouteEnabled,
        toolCalls: currentToolCalls,
      );
      if (fastImageRouteEnabled && !useFastToolRoute) {
        AppLogger.info(_logTag, '快速生图路由回落常规工具串行执行', metadata: {
          'round': round,
          'toolNames': currentToolCalls.map((t) => t.name).toList(),
        });
      }

      final toolTrace = roundTrace?.startChild('执行工具调用');
      toolTrace?.note('工具', metadata: {
        'count': currentToolCalls.length,
        'names': currentToolCalls.map((t) => t.name).toList(),
        'parallel': useFastToolRoute,
      });

      final toolResults = <ToolResult>[];
      final toolOutcomes = <_ToolExecutionOutcome>[];
      if (useFastToolRoute) {
        final outcomes = await Future.wait([
          for (final tc in currentToolCalls)
            _executeToolCall(
              toolCall: tc,
              effectivePlugins: effectivePlugins,
              availableTools: availableTools,
              toolTimeout: toolTimeout,
              flowSettings: flowSettings,
              onToolExecuting: onToolExecuting,
              drawImageStableReviewEnabled: drawImageStableReviewEnabled,
              sessionId: sessionId,
              turnId: effectiveTurnId,
              boundImageToolPresetName: config.boundImageToolPresetName,
              boundImageArtistPresetName: config.boundImageArtistPresetName,
              traceContext: traceContext,
              round: round,
              useFastToolRoute: useFastToolRoute,
            ),
        ]);
        toolOutcomes.addAll(outcomes);
        for (final outcome in outcomes) {
          collectToolOutcome(outcome, toolResults);
        }
      } else {
        for (final tc in currentToolCalls) {
          final outcome = await _executeToolCall(
            toolCall: tc,
            effectivePlugins: effectivePlugins,
            availableTools: availableTools,
            toolTimeout: toolTimeout,
            flowSettings: flowSettings,
            onToolExecuting: onToolExecuting,
            drawImageStableReviewEnabled: drawImageStableReviewEnabled,
            sessionId: sessionId,
            turnId: effectiveTurnId,
            boundImageToolPresetName: config.boundImageToolPresetName,
            boundImageArtistPresetName: config.boundImageArtistPresetName,
            traceContext: traceContext,
            round: round,
            useFastToolRoute: useFastToolRoute,
          );
          toolOutcomes.add(outcome);
          collectToolOutcome(outcome, toolResults);
        }
      }
      toolTrace?.end();
      executedAnyTool = true;
      allToolCalls.addAll(currentToolCalls);
      allRawToolResults.addAll(toolResults);
      final encodedToolCalls = _encodeToolCallsForLog(currentToolCalls);
      final encodedToolResults = _encodeToolResultsForLog(toolResults);
      Map<String, dynamic>? toolPayloadRef;
      int? toolEventSeq;
      if (traceContext != null) {
        toolPayloadRef = await TraceStore.instance.writePayload(
          traceId: traceContext.traceId,
          sessionId: traceContext.sessionId,
          turnId: traceContext.turnId,
          roundIndex: round,
          stage: TraceStage.toolExecFinished.value,
          source: 'ChatSendApiRunner',
          payload: {
            'rawToolCalls': encodedToolCalls,
            'rawToolResults': encodedToolResults,
          },
        );
        final toolTraceEvent = await TraceStore.instance.record(
          traceId: traceContext.traceId,
          sessionId: traceContext.sessionId,
          turnId: traceContext.turnId,
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
      ApiLogger.add(ApiLogEntry(
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
      ));
      if (traceContext != null) {
        await TraceStore.instance.record(
          traceId: traceContext.traceId,
          sessionId: traceContext.sessionId,
          turnId: traceContext.turnId,
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

      final shouldContinueFastFollowup = useFastToolRoute &&
          toolOutcomes.any((o) => o.isAsyncAcceptedDrawImage);
      if (shouldContinueFastFollowup) {
        // 保留已流出的前置话术，后续轮次只继续追加正文，不再清屏重置。
      }

      if (useFastToolRoute && !shouldContinueFastFollowup) {
        AppLogger.info(_logTag, '快速生图路由停止后续模型轮次', metadata: {
          'round': round,
        });
        roundTrace?.end(additionalMessage: 'fast mode stop');
        break;
      }

      if (round == maxRounds) {
        if (useFastToolRoute && shouldContinueFastFollowup) {
          AppLogger.info(_logTag, '快速生图路由达到补充轮次上限', metadata: {
            'round': round,
            'maxRounds': maxRounds,
          });
          roundTrace?.end(additionalMessage: 'fast follow-up max round');
        } else {
          AppLogger.warning(_logTag, '达到最大回合数',
              metadata: {'maxRounds': maxRounds});
          roundTrace?.end(additionalMessage: '达到最大回合数');
        }
        break;
      }

      if (shouldContinueFastFollowup) {
        if (remainingFastFollowupRounds <= 0) {
          AppLogger.info(_logTag, '快速生图路由达到补充轮次上限', metadata: {
            'round': round,
            'maxRounds': _maxFastFollowupRounds + 1,
          });
          roundTrace?.end(additionalMessage: 'fast follow-up max round');
          break;
        }
        remainingFastFollowupRounds -= 1;
      }

      final assistantMessage = usesFallbackToolCalls
          ? _buildFallbackAssistantMessageForToolCalls(
              currentToolCalls,
              adapter.name,
            )
          : _buildAssistantMessageFromRich(lastRich, adapter.name);
      final toolResultMessages = adapter.buildToolResultMessages(
        assistantMessage: assistantMessage,
        toolResults: toolResults,
      );
      final normalizedToolResultMessages = !supportsVision
          ? _sanitizeMessagesForNonVisionModel(toolResultMessages)
          : toolResultMessages;
      var nextRoundMessages = List<Map<String, dynamic>>.from(
        normalizedToolResultMessages,
      );
      if (drawImageStableReviewEnabled &&
          pendingStableReviewImages.isNotEmpty) {
        final reviewMessages = await _buildStableDrawImageReviewMessages(
          pendingStableReviewImages,
        );
        if (reviewMessages.isNotEmpty) {
          nextRoundMessages = [...nextRoundMessages, ...reviewMessages];
        }
      }
      currentMessages = [...currentMessages, ...nextRoundMessages];

      roundTrace?.note('追加工具结果', metadata: {
        'newMessagesCount': nextRoundMessages.length,
        'totalMessages': currentMessages.length,
        'pendingStableReviewImages': pendingStableReviewImages.length,
      });
      roundTrace?.end(additionalMessage: 'continue next round');
    }

    var finalAssistantText = lastRich?.text ?? '';
    final normalizedFinalText =
        _normalizeRoundNarrativeText(finalAssistantText);
    if (preToolNarrativeTexts.isNotEmpty) {
      final mergedTexts = <String>[...preToolNarrativeTexts];
      if (normalizedFinalText.isNotEmpty &&
          !_looksLikeToolInstructionText(normalizedFinalText)) {
        mergedTexts.add(normalizedFinalText);
      }
      finalAssistantText = _mergeNarrativeTexts(mergedTexts);
    } else {
      finalAssistantText = normalizedFinalText;
    }
    final generatedImageCount =
        allToolContents.whereType<PluginImageContent>().length;
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
      finalAssistantText =
          _stripStandaloneImagePlaceholders(finalAssistantText);
    }
    if (executedAnyTool && finalAssistantText.trim().isEmpty) {
      finalAssistantText = _buildToolCompletionSummary(
        generatedImageCount: generatedImageCount,
        hasAudio: allToolAudioResults.isNotEmpty,
      );
    }

    apiCallTrace?.note('完成', metadata: {
      'textLength': finalAssistantText.length,
      'toolResults': lastRich?.toolResults.length ?? 0,
    });
    apiCallTrace?.end(additionalMessage: 'API调用成功');

    final pluginTrace = trace?.startChild('运行插件');
    final pluginResult =
        await _processResponseWithPlugins(effectivePlugins, finalAssistantText);

    pluginTrace?.note('插件处理', metadata: {
      'original': finalAssistantText.length,
      'processed': pluginResult.processedText.length,
      'events': pluginResult.events.length,
    });
    pluginTrace?.end();
    Map<String, dynamic>? finalPayloadRef;
    int? finalEventSeq;
    if (traceContext != null) {
      finalPayloadRef = await TraceStore.instance.writePayload(
        traceId: traceContext.traceId,
        sessionId: traceContext.sessionId,
        turnId: traceContext.turnId,
        roundIndex: lastRoundIndex,
        stage: TraceStage.finalReplyReady.value,
        source: 'ChatSendApiRunner',
        payload: {
          'rawAiResponse': finalAssistantText,
          'finalReply': pluginResult.processedText,
        },
      );
      final traceEvent = await TraceStore.instance.record(
        traceId: traceContext.traceId,
        sessionId: traceContext.sessionId,
        turnId: traceContext.turnId,
        roundIndex: lastRoundIndex,
        stage: TraceStage.finalReplyReady,
        source: 'ChatSendApiRunner',
        payloadRef: finalPayloadRef,
        meta: {
          'rawReplyLength': finalAssistantText.length,
          'finalReplyLength': pluginResult.processedText.length,
        },
      );
      finalEventSeq = traceEvent.eventSeq;
    }
    ApiLogger.add(ApiLogEntry(
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
      rawAiResponse: finalAssistantText,
      finalReply: pluginResult.processedText,
      stage: TraceStage.finalReplyReady.value,
      stageStatus: TraceEventStatus.success.value,
      source: 'ChatSendApiRunner',
      eventSeq: finalEventSeq,
      payloadRef: finalPayloadRef,
    ));

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
      replyText: shouldSuppressStatusText ? '' : finalAssistantText,
      processedText: shouldSuppressStatusText ? '' : pluginResult.processedText,
      pluginEvents: allEvents,
      pluginContents: allContents,
      toolResults: lastRich?.toolResults ?? [],
      toolAudioResults: allToolAudioResults,
      toolCalls: allToolCalls,
      rawToolResults: allRawToolResults,
    );
  }

  Future<PluginProcessResult> _processResponseWithPlugins(
    List<Plugin> plugins,
    String text,
  ) async {
    if (plugins.isEmpty) {
      return PluginProcessResult(processedText: text, events: const []);
    }

    String currentText = text;
    final allEvents = <PluginEvent>[];
    final allContents = <PluginContent>[];

    for (final plugin in plugins) {
      try {
        final result = await plugin.processResponse(currentText);
        currentText = result.processedText;
        allEvents.addAll(result.events);
        allContents.addAll(result.contents);
      } catch (e) {
        AppLogger.warning(_logTag, '插件响应处理失败', metadata: {
          'pluginId': plugin.id,
          'error': e.toString(),
        });
      }
    }

    return PluginProcessResult(
      processedText: currentText,
      events: allEvents,
      contents: allContents,
    );
  }
}
