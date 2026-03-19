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

    Future<_ToolExecutionOutcome> executeToolCall(
      ToolCall tc, {
      required int round,
      required bool useFastToolRoute,
    }) async {
      final startedAt = DateTime.now();
      if (traceContext != null) {
        await TraceStore.instance.record(
          traceId: traceContext.traceId,
          sessionId: traceContext.sessionId,
          turnId: traceContext.turnId,
          roundIndex: round,
          stage: TraceStage.toolExecStarted,
          status: TraceEventStatus.running,
          source: 'ChatSendApiRunner',
          startedAt: startedAt,
          endedAt: startedAt,
          durationMs: 0,
          meta: {
            'toolName': tc.name,
            'toolCallId': tc.id,
          },
        );
      }

      var finishedStatus = TraceEventStatus.success;
      var finishMeta = <String, dynamic>{
        'toolName': tc.name,
        'toolCallId': tc.id,
      };
      try {
        final tool = _findToolByName(
          effectivePlugins,
          tc.name,
          availableTools: availableTools,
        );
        if (tool == null) {
          AppLogger.warning(_logTag, 'Tool not found',
              metadata: {'name': tc.name});
          finishedStatus = TraceEventStatus.failed;
          finishMeta['error'] = 'tool_not_found';
          return _ToolExecutionOutcome(
            toolResult: ToolResult(
              toolCallId: tc.id,
              name: tc.name,
              result: jsonEncode({'error': 'Tool not found: ${tc.name}'}),
            ),
          );
        }

        onToolExecuting?.call(tc.name);
        final actualFlowMode = useFastToolRoute
            ? EffectiveImageGenerationRoute.fast.value
            : EffectiveImageGenerationRoute.stable.value;
        final executionArgs = _buildToolArgumentsForExecution(
          toolName: tc.name,
          originalArguments: tc.arguments,
          useFastToolRoute: useFastToolRoute,
          flowMode: actualFlowMode,
          sessionId: sessionId,
          turnId: effectiveTurnId,
          roleToolPresetName: config.boundImageToolPresetName,
          roleArtistPresetName: config.boundImageArtistPresetName,
        );
        AppLogger.info(_logTag, '执行工具调用', metadata: {
          'round': round,
          'name': tc.name,
          'args': executionArgs,
        });

        final result = await tool.handler(executionArgs).timeout(toolTimeout);
        final resultStr = result ?? '';
        finishMeta['rawResultLength'] = resultStr.length;
        AppLogger.info(_logTag, '工具调用完成', metadata: {
          'name': tc.name,
          'result': resultStr,
        });

        if (tc.name == 'speak') {
          ToolAudioResult? audioResult;
          try {
            final parsed = jsonDecode(resultStr) as Map<String, dynamic>;
            final success = parsed['success'] == true;
            final audioUrl = parsed['audioUrl'] as String?;
            final text = parsed['text'] as String? ?? '';
            if (success && audioUrl != null && audioUrl.isNotEmpty) {
              audioResult = ToolAudioResult(audioUrl: audioUrl, text: text);
              finishMeta['audioProduced'] = true;
              AppLogger.info(_logTag, '收集到 speak 工具音频', metadata: {
                'audioUrlLength': audioUrl.length,
                'text': text,
              });
            }
          } catch (e) {
            AppLogger.warning(_logTag, '解析 speak 结果失败',
                metadata: {'error': e.toString()});
          }

          return _ToolExecutionOutcome(
            toolResult: ToolResult(
              toolCallId: tc.id,
              name: tc.name,
              // 参考：https://github.com/openai/codex/issues/6426 (tool output truncation)
              result: '{"success": true, "message": "语音已播放给用户"}',
            ),
            audioResult: audioResult,
          );
        }

        if (tc.name == 'draw_image') {
          final asyncAccepted = _isAsyncDrawImageAccepted(resultStr);
          final imageContents = _extractToolImageContents(resultStr);
          final actualFlowMode = useFastToolRoute
              ? EffectiveImageGenerationRoute.fast.value
              : EffectiveImageGenerationRoute.stable.value;
          final requiresStableVisionReview = drawImageStableReviewEnabled &&
              !useFastToolRoute &&
              imageContents.isNotEmpty;
          finishMeta['imageCount'] = imageContents.length;
          finishMeta['asyncAccepted'] = asyncAccepted;
          finishMeta['stableVisionReview'] = requiresStableVisionReview;
          finishMeta['actualFlowMode'] = actualFlowMode;
          if (imageContents.isNotEmpty) {
            AppLogger.info(_logTag, 'Collected draw_image tool images',
                metadata: {
                  'count': imageContents.length,
                });
          }
          return _ToolExecutionOutcome(
            toolResult: ToolResult(
              toolCallId: tc.id,
              name: tc.name,
              result: _buildToolResultForModel(
                toolName: tc.name,
                rawResult: resultStr,
                drawImageDeliveredToChat: !requiresStableVisionReview,
                drawImageRequiresReview: requiresStableVisionReview,
              ),
            ),
            imageContents: imageContents,
            isAsyncAcceptedDrawImage: asyncAccepted,
          );
        }

        return _ToolExecutionOutcome(
          toolResult: ToolResult(
            toolCallId: tc.id,
            name: tc.name,
            result: _buildToolResultForModel(
              toolName: tc.name,
              rawResult: resultStr,
            ),
          ),
        );
      } on TimeoutException {
        finishedStatus = TraceEventStatus.failed;
        finishMeta['error'] = 'timeout';
        AppLogger.warning(_logTag, '工具调用超时', metadata: {
          'name': tc.name,
          'timeoutSec': flowSettings.toolTimeoutSeconds,
        });
        return _ToolExecutionOutcome(
          toolResult: ToolResult(
            toolCallId: tc.id,
            name: tc.name,
            result: jsonEncode(
              {
                'error':
                    'Tool timeout after ${flowSettings.toolTimeoutSeconds}s'
              },
            ),
          ),
        );
      } catch (e) {
        finishedStatus = TraceEventStatus.failed;
        finishMeta['error'] = e.toString();
        AppLogger.error(_logTag, '工具调用失败', metadata: {
          'name': tc.name,
          'error': e.toString(),
        });
        return _ToolExecutionOutcome(
          toolResult: ToolResult(
            toolCallId: tc.id,
            name: tc.name,
            result: jsonEncode({'error': e.toString()}),
          ),
        );
      } finally {
        if (traceContext != null) {
          final endedAt = DateTime.now();
          await TraceStore.instance.record(
            traceId: traceContext.traceId,
            sessionId: traceContext.sessionId,
            turnId: traceContext.turnId,
            roundIndex: round,
            stage: TraceStage.toolExecFinished,
            status: finishedStatus,
            source: 'ChatSendApiRunner',
            startedAt: startedAt,
            endedAt: endedAt,
            durationMs: endedAt.difference(startedAt).inMilliseconds,
            meta: finishMeta,
          );
        }
      }
    }

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
            executeToolCall(
              tc,
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
          final outcome = await executeToolCall(
            tc,
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

  AITool? _findToolByName(
    List<Plugin> plugins,
    String name, {
    List<AITool>? availableTools,
  }) {
    if (availableTools != null) {
      for (final tool in availableTools) {
        if (tool.name == name) return tool;
      }
      return null;
    }

    for (final plugin in plugins) {
      try {
        final tools = plugin.getTools();
        for (final tool in tools) {
          if (tool.name == name) return tool;
        }
      } catch (e) {
        AppLogger.warning(_logTag, '插件工具查找失败', metadata: {
          'pluginId': plugin.id,
          'toolName': name,
          'error': e.toString(),
        });
      }
    }
    return null;
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

  String? _encodeToolCallsForLog(List<ToolCall> calls) {
    if (calls.isEmpty) return null;
    return jsonEncode([
      for (final c in calls)
        {
          'id': c.id,
          'name': c.name,
          'arguments': c.arguments,
        }
    ]);
  }

  String? _encodeToolResultsForLog(List<ToolResult> results) {
    if (results.isEmpty) return null;
    return jsonEncode([
      for (final r in results)
        {
          'toolCallId': r.toolCallId,
          'name': r.name,
          'result': r.result,
        }
    ]);
  }

  List<PluginImageContent> _extractToolImageContents(String result) {
    final trimmed = result.trim();
    if (trimmed.isEmpty) return const <PluginImageContent>[];

    final payload = _tryParseJsonMap(trimmed);
    if (payload == null) return const <PluginImageContent>[];

    final contents = <PluginImageContent>[];
    final seenPaths = <String>{};

    void collect(dynamic value, {String? fallbackCaption}) {
      String localPath = '';
      String? caption;

      if (value is Map) {
        final map = _toStringDynamicMap(value);
        localPath = (map['localPath'] ??
                    map['image_path'] ??
                    map['imagePath'] ??
                    map['path'])
                ?.toString()
                .trim() ??
            '';
        caption = map['caption']?.toString().trim();
        caption ??= map['prompt']?.toString().trim();
      } else if (value is String) {
        localPath = value.trim();
      }

      if (localPath.isEmpty || !seenPaths.add(localPath)) {
        return;
      }

      final effectiveCaption = (caption == null || caption.isEmpty)
          ? (fallbackCaption == null || fallbackCaption.isEmpty
              ? null
              : fallbackCaption)
          : caption;
      contents.add(PluginImageContent(localPath, caption: effectiveCaption));
    }

    final promptCaption = payload['prompt']?.toString().trim();
    final images = payload['images'];
    if (images is List) {
      for (final image in images) {
        collect(image, fallbackCaption: promptCaption);
      }
    }

    collect(payload['image'], fallbackCaption: promptCaption);
    collect(payload['image_path'], fallbackCaption: promptCaption);
    collect(payload['imagePath'], fallbackCaption: promptCaption);
    collect(payload['localPath'], fallbackCaption: promptCaption);
    collect(payload['path'], fallbackCaption: promptCaption);

    final data = payload['data'];
    if (data is Map) {
      final dataMap = _toStringDynamicMap(data);
      collect(dataMap['image'], fallbackCaption: promptCaption);
      collect(dataMap['image_path'], fallbackCaption: promptCaption);
      collect(dataMap['imagePath'], fallbackCaption: promptCaption);
      collect(dataMap['localPath'], fallbackCaption: promptCaption);
      collect(dataMap['path'], fallbackCaption: promptCaption);
      final dataImages = dataMap['images'];
      if (dataImages is List) {
        for (final image in dataImages) {
          collect(image, fallbackCaption: promptCaption);
        }
      }
    }

    return contents;
  }

  List<PluginImageContent> _selectStableReviewImages(
    List<PluginImageContent> images,
  ) {
    if (images.isEmpty) return const <PluginImageContent>[];
    return <PluginImageContent>[images.first];
  }

  Future<List<Map<String, dynamic>>> _buildStableDrawImageReviewMessages(
    List<PluginImageContent> images,
  ) async {
    if (images.isEmpty) return const <Map<String, dynamic>>[];

    final content = <Map<String, dynamic>>[
      <String, dynamic>{
        'type': 'text',
        'text': _stableDrawImageReviewInstruction,
      },
    ];

    for (final image in images) {
      final imagePart = await _buildLocalImageInputPart(image.localPath);
      if (imagePart != null) {
        content.add(imagePart);
      }
    }

    if (content.length <= 1) {
      AppLogger.warning(_logTag, 'Stable draw_image review image load failed');
      return const <Map<String, dynamic>>[];
    }

    return <Map<String, dynamic>>[
      <String, dynamic>{
        'role': 'user',
        'content': content,
      },
    ];
  }

  Future<Map<String, dynamic>?> _buildLocalImageInputPart(
      String localPath) async {
    final trimmed = localPath.trim();
    if (trimmed.isEmpty) return null;

    try {
      final file = File(trimmed);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      final mime = MimeUtils.guessImageMimeType(trimmed);
      final base64 = base64Encode(bytes);
      return <String, dynamic>{
        'type': 'image_url',
        'image_url': <String, dynamic>{
          'url': 'data:$mime;base64,$base64',
        },
      };
    } catch (e) {
      AppLogger.warning(_logTag, 'Stable draw_image review image read failed',
          metadata: {
            'path': trimmed,
            'error': e.toString(),
          });
      return null;
    }
  }

  bool _containsImagePlaceholder(String text) =>
      _imagePlaceholderRegex.hasMatch(text);

  List<ToolCall> _extractFallbackToolCalls(String text) =>
      _fallbackParser.extractFallbackToolCalls(text);

  Map<String, dynamic>? _tryParseJsonMap(String raw) =>
      _fallbackParser.tryParseJsonMap(raw);

  Map<String, dynamic> _toStringDynamicMap(Map raw) =>
      _fallbackParser.toStringDynamicMap(raw);

  String _buildToolCallSignature(ToolCall call) {
    final keys = call.arguments.keys.toList()..sort();
    final normalizedArgs = <String, dynamic>{};
    for (final key in keys) {
      normalizedArgs[key] = call.arguments[key];
    }
    return '${call.name}:${jsonEncode(normalizedArgs)}';
  }

  Map<String, dynamic> _buildToolArgumentsForExecution({
    required String toolName,
    required Map<String, dynamic> originalArguments,
    required bool useFastToolRoute,
    required String flowMode,
    required String sessionId,
    required String turnId,
    required String? roleToolPresetName,
    required String? roleArtistPresetName,
  }) {
    if (toolName != 'draw_image') {
      return originalArguments;
    }
    final args = Map<String, dynamic>.from(originalArguments);
    args['_aicove_flow_mode'] = flowMode;
    args['_aicove_session_id'] = sessionId;
    args['_aicove_turn_id'] = turnId;
    if (useFastToolRoute) {
      args['_aicove_async'] = true;
    }
    if (roleToolPresetName != null && roleToolPresetName.trim().isNotEmpty) {
      args['_aicove_role_tool_preset_name'] = roleToolPresetName.trim();
    }
    if (roleArtistPresetName != null &&
        roleArtistPresetName.trim().isNotEmpty) {
      args['_aicove_role_artist_preset_name'] = roleArtistPresetName.trim();
    }
    return args;
  }

  bool _shouldUseFastToolRoute({
    required bool fastModeEnabled,
    required List<ToolCall> toolCalls,
  }) {
    if (!fastModeEnabled || toolCalls.isEmpty) {
      return false;
    }
    return toolCalls.every((call) => call.name == 'draw_image');
  }

  bool _isAsyncDrawImageAccepted(String rawResult) {
    final payload = _tryParseJsonMap(rawResult.trim());
    if (payload == null) return false;
    final success = payload['success'];
    final successOk = success is bool ? success : true;
    if (!successOk) return false;

    final accepted = payload['accepted'] == true;
    final status = payload['status']?.toString().trim().toLowerCase() ?? '';
    final hasJobId = [
      payload['job_id'],
      payload['jobId'],
      payload['id'],
    ].any((v) => v != null && v.toString().trim().isNotEmpty);
    final isPendingStatus =
        status == 'pending' || status == 'accepted' || status == 'queued';

    return accepted || (hasJobId && isPendingStatus);
  }

  String _buildToolResultForModel({
    required String toolName,
    required String rawResult,
    bool drawImageDeliveredToChat = true,
    bool drawImageRequiresReview = false,
  }) {
    if (toolName != 'draw_image') {
      return rawResult;
    }

    final payload = _tryParseJsonMap(rawResult.trim());
    if (payload == null) {
      return rawResult;
    }

    final summary = <String, dynamic>{};
    void copyTrimmedString(String key, {String? toKey}) {
      final value = payload[key]?.toString().trim();
      if (value == null || value.isEmpty) return;
      summary[toKey ?? key] = value;
    }

    final success = payload['success'];
    if (success is bool) {
      summary['success'] = success;
    }

    final provider = payload['provider']?.toString().trim();
    if (provider != null && provider.isNotEmpty) {
      summary['provider'] = provider;
    }

    final model = payload['model']?.toString().trim();
    if (model != null && model.isNotEmpty) {
      summary['model'] = model;
    }

    final accepted = payload['accepted'];
    if (accepted is bool) {
      summary['accepted'] = accepted;
    }
    final status = payload['status']?.toString().trim();
    if (status != null && status.isNotEmpty) {
      summary['status'] = status;
    }
    final jobId = (payload['job_id'] ?? payload['jobId'] ?? payload['id'])
        ?.toString()
        .trim();
    if (jobId != null && jobId.isNotEmpty) {
      summary['job_id'] = jobId;
    }

    var imageCount = 0;
    final images = payload['images'];
    if (images is List) {
      imageCount = images.length;
    } else {
      final hasSingleImage = [
        payload['image'],
        payload['image_path'],
        payload['imagePath'],
        payload['localPath'],
        payload['path'],
      ].any((v) => v != null && v.toString().trim().isNotEmpty);
      if (hasSingleImage) {
        imageCount = 1;
      }
    }
    summary['image_count'] = imageCount;

    final prompt = payload['prompt']?.toString().trim();
    if (prompt != null && prompt.isNotEmpty) {
      summary['prompt'] = prompt;
    }
    copyTrimmedString('raw_prompt');
    copyTrimmedString('negative_prompt');
    copyTrimmedString('artist_preset_name');
    copyTrimmedString('artist_preset_source');
    copyTrimmedString('artist_prompt_prefix');
    copyTrimmedString('artist_negative_prompt');

    if (imageCount > 0) {
      summary['image_present'] = true;
      if (drawImageDeliveredToChat) {
        summary['delivered_to_chat'] = true;
      } else {
        summary['image_delivery_pending'] = true;
      }
      if (drawImageRequiresReview) {
        summary['image_review_pending'] = true;
      }
    } else if (accepted == true) {
      summary['image_delivery_pending'] = true;
    }

    final message = payload['message']?.toString().trim();
    if (message != null && message.isNotEmpty) {
      summary['message'] = message;
    }

    final error = payload['error']?.toString().trim();
    if (error != null && error.isNotEmpty) {
      summary['error'] = error;
    }

    return jsonEncode(summary);
  }

  String _sanitizeAssistantText(String text) {
    var cleaned = text;
    if (cleaned.trim().isEmpty) return cleaned.trim();

    cleaned = cleaned.replaceAll(
      RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false),
      '',
    );
    cleaned =
        cleaned.replaceAll(RegExp(r'</?think>', caseSensitive: false), '');

    cleaned = cleaned.replaceAllMapped(
      RegExp(r'\[(图片|image)\s*:\s*[^\]]*?\]', caseSensitive: false),
      (_) => '<image></image>',
    );
    cleaned = cleaned.replaceAllMapped(
      RegExp(r'<image>\s*</image>', caseSensitive: false),
      (_) => '<image></image>',
    );

    cleaned = cleaned.replaceAll(
      ChatRequestMessageBuilder.nonVisionImageContextRegex,
      '',
    );
    cleaned = cleaned.replaceAll(
      RegExp(
        '${RegExp.escape(_stableDrawImageReviewPrefix)}[^\\r\\n]*(?:\\r?\\n)?',
      ),
      '',
    );
    cleaned = cleaned.replaceAll(RegExp(r'\n{3,}'), '\n\n');

    return cleaned.trim();
  }

  String _stripStandaloneImagePlaceholders(String text) {
    var cleaned = text;
    if (cleaned.trim().isEmpty) return cleaned.trim();

    cleaned = cleaned.replaceAll(
      RegExp(
        r'^[ \t]*(?:<image>\s*</image>|\[(?:图片|image)(?:\s*:[^\]]*)?\])[ \t]*(?:\r?\n)?',
        caseSensitive: false,
        multiLine: true,
      ),
      '',
    );

    cleaned = cleaned.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return cleaned.trim();
  }

  bool _looksLikeToolInstructionText(String text) {
    if (text.trim().isEmpty) return false;
    if (text.contains('<execute_tool>')) return true;
    if (RegExp(r'"action"\s*:\s*"[a-zA-Z_][a-zA-Z0-9_]*"').hasMatch(text)) {
      return true;
    }
    if (RegExp(r'"action_input"\s*:').hasMatch(text)) return true;
    if (RegExp(
      r'^\s*\[(prompt|negative_prompt|size)\]\s*$',
      caseSensitive: false,
      multiLine: true,
    ).hasMatch(text)) {
      return true;
    }
    if (RegExp(r'\bdraw_image\s*\(', caseSensitive: false).hasMatch(text)) {
      return true;
    }
    return false;
  }

  String _normalizeRoundNarrativeText(String text) {
    final sanitized = _sanitizeAssistantText(text);
    if (sanitized.isEmpty) return '';
    return _stripStandaloneImagePlaceholders(sanitized);
  }

  String _mergeNarrativeTexts(List<String> texts) {
    final normalized = <String>[];
    final seen = <String>{};
    for (final text in texts) {
      final trimmed = text.trim();
      if (trimmed.isEmpty) continue;
      if (seen.add(trimmed)) {
        normalized.add(trimmed);
      }
    }
    return normalized.join('\n');
  }

  bool _shouldSuppressToolStatusText({
    required String text,
    required int generatedImageCount,
    required bool hasAudio,
    required int toolCallCount,
  }) {
    if (toolCallCount <= 0) return false;
    if (generatedImageCount <= 0 && !hasAudio) return false;

    final lines = text
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (lines.isEmpty) return false;
    return lines.every(_isToolStatusLine);
  }

  bool _isToolStatusLine(String line) {
    final normalized = line.trim();
    if (normalized.isEmpty) return false;

    final lowered = normalized.toLowerCase();
    if (RegExp(
      r'^(image generated and sent|images generated and sent \(\d+ total\)|tool call executed|audio output was also handled)[.!]?$',
    ).hasMatch(lowered)) {
      return true;
    }

    return RegExp(
      r'^(图片(?:已)?生成并发送|工具调用已执行|音频输出(?:也)?已处理)[。.!！]?$',
    ).hasMatch(normalized);
  }

  String _buildToolCompletionSummary({
    required int generatedImageCount,
    required bool hasAudio,
  }) {
    final chunks = <String>[];
    if (generatedImageCount > 0) {
      chunks.add(
        generatedImageCount == 1
            ? 'Image generated and sent.'
            : 'Images generated and sent ($generatedImageCount total).',
      );
    }
    if (hasAudio) {
      chunks.add('Audio output was also handled.');
    }
    if (chunks.isEmpty) {
      return 'Tool call executed.';
    }
    return chunks.join('\n');
  }

  Map<String, dynamic> _buildFallbackAssistantMessageForToolCalls(
    List<ToolCall> toolCalls,
    String adapterName,
  ) {
    if (adapterName != 'openai') {
      return <String, dynamic>{'content': ''};
    }
    return <String, dynamic>{
      'content': null,
      'tool_calls': [
        for (var i = 0; i < toolCalls.length; i++)
          {
            'id': toolCalls[i].id.trim().isNotEmpty
                ? toolCalls[i].id
                : 'fallback_tool_call_${i + 1}',
            'type': 'function',
            'function': {
              'name': toolCalls[i].name,
              'arguments': jsonEncode(toolCalls[i].arguments),
            },
          }
      ],
    };
  }

  Map<String, dynamic> _buildAssistantMessageFromRich(
      SendMessageRichResult rich, String adapterName) {
    switch (adapterName) {
      case 'claude':
      case 'anthropic':
        return rich.rawResponse ?? {'content': []};
      case 'gemini':
      case 'google':
        final candidates = (rich.rawResponse?['candidates'] as List?) ?? [];
        if (candidates.isNotEmpty) {
          final first = candidates.first as Map<String, dynamic>;
          return {'content': first['content']};
        }
        return {
          'content': {'parts': []}
        };
      default:
        final choices = (rich.rawResponse?['choices'] as List?) ?? [];
        if (choices.isNotEmpty) {
          final first = choices.first as Map<String, dynamic>;
          return first['message'] as Map<String, dynamic>? ?? {};
        }
        return {};
    }
  }

  List<Map<String, dynamic>> _sanitizeMessagesForNonVisionModel(
    List<Map<String, dynamic>> messages,
  ) {
    final sanitized = <Map<String, dynamic>>[];
    var removedImageParts = 0;

    for (final message in messages) {
      final map = Map<String, dynamic>.from(message);
      final role = (map['role'] ?? '').toString().toLowerCase();

      final contentResult = _sanitizeNodeRemovingImageParts(map['content']);
      removedImageParts += contentResult.removed;
      if (map.containsKey('content')) {
        map['content'] = contentResult.value;
      }

      final partsResult = _sanitizeNodeRemovingImageParts(map['parts']);
      removedImageParts += partsResult.removed;
      if (map.containsKey('parts')) {
        map['parts'] = partsResult.value;
      }

      if (map['content'] is List && (map['content'] as List).isEmpty) {
        if (role == 'assistant' &&
            (map.containsKey('tool_calls') ||
                map.containsKey('function_call'))) {
          map['content'] = null;
        } else {
          map['content'] = '';
        }
      }
      if (map['parts'] is List && (map['parts'] as List).isEmpty) {
        map['parts'] = <Map<String, dynamic>>[];
      }

      sanitized.add(map);
    }

    if (removedImageParts > 0) {
      AppLogger.info(_logTag, 'Removed image parts for non-vision model',
          metadata: {
            'removedImageParts': removedImageParts,
            'messageCount': messages.length,
          });
    }
    return sanitized;
  }

  _SanitizeResult _sanitizeNodeRemovingImageParts(dynamic node) {
    if (node == null) {
      return const _SanitizeResult(value: null, removed: 0);
    }

    if (node is List) {
      final list = <dynamic>[];
      var removed = 0;
      for (final item in node) {
        final child = _sanitizeNodeRemovingImageParts(item);
        removed += child.removed;
        if (!child.dropCurrentNode) {
          list.add(child.value);
        }
      }
      return _SanitizeResult(value: list, removed: removed);
    }

    if (node is Map) {
      final map = <String, dynamic>{};
      node.forEach((key, value) {
        map[key.toString()] = value;
      });

      if (_isImagePartMap(map)) {
        return const _SanitizeResult(
          value: null,
          removed: 1,
          dropCurrentNode: true,
        );
      }

      var removed = 0;
      final normalized = <String, dynamic>{};
      for (final entry in map.entries) {
        final child = _sanitizeNodeRemovingImageParts(entry.value);
        removed += child.removed;
        if (entry.value is List &&
            child.value is List &&
            (child.value as List).isEmpty) {
          normalized[entry.key] = child.value;
          continue;
        }
        normalized[entry.key] = child.value;
      }

      return _SanitizeResult(value: normalized, removed: removed);
    }

    return _SanitizeResult(value: node, removed: 0);
  }

  bool _isImagePartMap(Map<String, dynamic> part) {
    final type = (part['type'] ?? '').toString().toLowerCase();
    if (type == 'image_url' || type == 'input_image' || type == 'image') {
      return true;
    }

    if (part.containsKey('image_url')) return true;

    if (part.containsKey('inlineData')) {
      final inline = part['inlineData'];
      if (inline is Map) {
        final mime = inline['mimeType']?.toString().toLowerCase() ?? '';
        if (mime.isEmpty || mime.startsWith('image/')) {
          return true;
        }
      } else {
        return true;
      }
    }

    if (part.containsKey('fileData')) {
      final file = part['fileData'];
      if (file is Map) {
        final mime = file['mimeType']?.toString().toLowerCase() ?? '';
        if (mime.startsWith('image/')) {
          return true;
        }
      }
    }

    return false;
  }
}

class _ToolExecutionOutcome {
  final ToolResult toolResult;
  final ToolAudioResult? audioResult;
  final List<PluginImageContent> imageContents;
  final bool isAsyncAcceptedDrawImage;

  const _ToolExecutionOutcome({
    required this.toolResult,
    this.audioResult,
    this.imageContents = const <PluginImageContent>[],
    this.isAsyncAcceptedDrawImage = false,
  });
}

class _VisibleAssistantStreamFilter {
  static const String _imageOpenTagPrefix = '<image';
  static const String _imageCloseTag = '</image>';

  String _pending = '';
  bool _insideImageTag = false;

  String consume(String delta) {
    if (delta.isEmpty) return '';
    _pending = '$_pending$delta';
    final output = StringBuffer();

    while (_pending.isNotEmpty) {
      if (_insideImageTag) {
        final lowerPending = _pending.toLowerCase();
        final closeIndex = lowerPending.indexOf(_imageCloseTag);
        if (closeIndex < 0) {
          _pending = _retainTail(_pending, _imageCloseTag.length - 1);
          break;
        }
        _pending = _pending.substring(closeIndex + _imageCloseTag.length);
        _insideImageTag = false;
        continue;
      }

      final lowerPending = _pending.toLowerCase();
      final openIndex = lowerPending.indexOf(_imageOpenTagPrefix);
      if (openIndex >= 0) {
        if (openIndex > 0) {
          output.write(_pending.substring(0, openIndex));
        }
        final tagEndIndex = _pending.indexOf('>', openIndex);
        if (tagEndIndex < 0) {
          _pending = _pending.substring(openIndex);
          break;
        }
        _pending = _pending.substring(tagEndIndex + 1);
        _insideImageTag = true;
        continue;
      }

      final partialPrefixLength =
          _findTrailingPrefixLength(lowerPending, _imageOpenTagPrefix);
      if (partialPrefixLength > 0) {
        final visibleEnd = _pending.length - partialPrefixLength;
        if (visibleEnd > 0) {
          output.write(_pending.substring(0, visibleEnd));
        }
        _pending = _pending.substring(visibleEnd);
        break;
      }

      output.write(_pending);
      _pending = '';
    }

    return output.toString();
  }

  String _retainTail(String value, int maxLength) {
    if (value.length <= maxLength) return value;
    return value.substring(value.length - maxLength);
  }

  int _findTrailingPrefixLength(String value, String prefix) {
    final maxLength =
        value.length < prefix.length ? value.length : prefix.length;
    for (var length = maxLength; length > 0; length--) {
      if (prefix.startsWith(value.substring(value.length - length))) {
        return length;
      }
    }
    return 0;
  }
}

class _SanitizeResult {
  final dynamic value;
  final int removed;
  final bool dropCurrentNode;

  const _SanitizeResult({
    required this.value,
    required this.removed,
    this.dropCurrentNode = false,
  });
}
