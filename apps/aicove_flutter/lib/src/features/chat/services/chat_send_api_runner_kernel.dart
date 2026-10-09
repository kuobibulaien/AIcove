part of 'chat_send_api_runner.dart';

/// [ApiRunner] backed by the agent kernel (ADR0064, batch 1).
///
/// Equivalent extraction of [ChatSendApiRunner.executeApiCall]: every branch
/// lives in a fixed kernel stage and reuses the same library helpers. The
/// preset runtime is owned by a run scope released after result processing.
class KernelApiRunner implements ApiRunner {
  const KernelApiRunner()
    : _agentClientFactory = ChatSendApiRunner._defaultAgentClientFactory,
      _legacy = const ChatSendApiRunner(),
      _scopeFactory = kernel.KernelScope.new;

  /// [scopeFactory] lets tests observe when the run scope is released.
  KernelApiRunner.withAgentClientFactory({
    required AgentApiClient Function(Duration timeout) agentClientFactory,
    kernel.KernelScope Function() scopeFactory = kernel.KernelScope.new,
  }) : _agentClientFactory = agentClientFactory,
       _scopeFactory = scopeFactory,
       _legacy = ChatSendApiRunner.withAgentClientFactory(
         agentClientFactory: agentClientFactory,
       );

  static const String _logTag = 'KernelApiRunner';

  final _AgentClientFactory _agentClientFactory;
  final ChatSendApiRunner _legacy;
  final kernel.KernelScope Function() _scopeFactory;

  /// A run with no rounds never reaches the kernel loop; the legacy runner
  /// already defines that degenerate result.
  static bool needsLegacyRunner({required int maxRounds}) => maxRounds < 1;

  @override
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
    if (needsLegacyRunner(maxRounds: maxRounds)) {
      AppLogger.info(
        _logTag,
        '轮次上限小于 1，交由旧执行器',
        metadata: {'maxRounds': maxRounds},
      );
      return _legacy.executeApiCall(
        config: config,
        sessionId: sessionId,
        userText: userText,
        effectivePlugins: effectivePlugins,
        availableTools: availableTools,
        turnId: turnId,
        trace: trace,
        maxRounds: maxRounds,
        onToolExecuting: onToolExecuting,
        enableStreaming: enableStreaming,
        onStreamTextDelta: onStreamTextDelta,
        onStreamTextReset: onStreamTextReset,
        onStreamToolCallObserved: onStreamToolCallObserved,
        onStreamingFallback: onStreamingFallback,
        traceContext: traceContext,
      );
    }

    final scope = _scopeFactory();
    try {
      final presetRuntime = config.presetScript == null
          ? null
          : await QuickJsPresetRuntime.open(config.presetScript!);
      if (presetRuntime != null) scope.addCloser(presetRuntime.close);
      final run = _KernelRun(
        presetRuntime: presetRuntime,
        config: config,
        sessionId: sessionId,
        userText: userText,
        effectivePlugins: effectivePlugins,
        availableTools: availableTools ?? config.boundTools,
        turnId: turnId,
        trace: trace,
        maxRounds: maxRounds,
        onToolExecuting: onToolExecuting,
        enableStreaming: enableStreaming,
        onStreamTextDelta: onStreamTextDelta,
        onStreamTextReset: onStreamTextReset,
        onStreamToolCallObserved: onStreamToolCallObserved,
        onStreamingFallback: onStreamingFallback,
        traceContext: traceContext,
        agentClientFactory: _agentClientFactory,
      );
      final loop = kernel.AgentLoop(
        stages: kernel.StagePipeline(
          preparer: run,
          model: run,
          unpacker: run,
          resolver: run,
          preTool: run,
          tools: run,
          postTool: run,
          encoder: run,
        ),
        maxRounds: maxRounds,
      );
      final kernel.AgentLoopResult result;
      try {
        result = await loop.run(run.initialMessages);
      } on kernel.KernelContextOverflow catch (overflow, stack) {
        // Non-recoverable overflow: rethrow the provider error unchanged.
        Error.throwWithStackTrace(
          overflow.cause ?? overflow,
          overflow.causeStackTrace ?? stack,
        );
      }
      if (result.status == kernel.LoopStatus.cancelled) {
        throw const kernel.KernelCancelledException();
      }
      return await run.finalize(_legacy);
    } finally {
      // After result processing: plugins and the preset runtime stay usable
      // until the ApiCallResult is built.
      await scope.dispose();
    }
  }
}

/// Mutable state of one kernel run plus every stage implementation. Each
/// method mirrors a section of [ChatSendApiRunner.executeApiCall].
class _KernelRun
    implements
        kernel.RoundPreparer,
        kernel.ModelPort,
        kernel.ResponseUnpacker,
        kernel.ToolCallResolver,
        kernel.PreToolDecision,
        kernel.ToolBatchExecutor,
        kernel.PostToolDecision,
        kernel.ContinuationEncoder {
  _KernelRun({
    required this.presetRuntime,
    required this.config,
    required this.sessionId,
    required this.userText,
    required this.effectivePlugins,
    required List<AITool>? availableTools,
    required String? turnId,
    required TraceLogger? trace,
    required this.maxRounds,
    required this.onToolExecuting,
    required bool enableStreaming,
    required this.onStreamTextDelta,
    required this.onStreamTextReset,
    required this.onStreamToolCallObserved,
    required this.onStreamingFallback,
    required this.traceContext,
    required _AgentClientFactory agentClientFactory,
  }) : _trace = trace {
    final preset = presetRuntime;
    if (preset != null && preset.businessTools.isNotEmpty) {
      availableTools = [
        ...availableTools ??
            effectivePlugins.expand((plugin) => plugin.getTools()),
      ];
    }
    requestTools = [...?config.tools, ...?preset?.tools];
    final toolNames = <String>{};
    for (final schema in requestTools) {
      final name = (schema['function'] as Map)['name'] as String;
      if (!toolNames.add(name)) throw StateError('重复工具名称：$name');
    }
    for (final schema in preset?.businessTools ?? <Map<String, dynamic>>[]) {
      final definition = schema['function'] as Map;
      final name = definition['name'] as String;
      availableTools!.add(
        AITool(
          name: name,
          description: definition['description'] as String,
          parameters: const {},
          handler: (args) => preset!.action(name, args),
        ),
      );
    }
    this.availableTools = availableTools;
    requestOptions = preset?.toolChoice == null
        ? config.providerRequestOptions
        : (config.providerRequestOptions ?? const ProviderChatRequestOptions())
              .copyWith(toolChoice: preset!.toolChoice);
    for (final diagnostic in preset?.diagnostics ?? <String>[]) {
      AppLogger.info(_logTag, 'Preset transport: $diagnostic');
      trace?.note('预设传输', metadata: {'diagnostic': diagnostic});
    }
    flowSettings = config.settings.callFlowSettings;
    final effectiveImageRoute = config.settings
        .resolveEffectiveImageGenerationRoute(config.modelFullId);
    final stableImageRouteEnabled =
        effectiveImageRoute == EffectiveImageGenerationRoute.stable;
    fastImageRouteEnabled =
        effectiveImageRoute == EffectiveImageGenerationRoute.fast;
    final modelTimeout = Duration(seconds: flowSettings.modelTimeoutSeconds);
    toolTimeout = Duration(seconds: flowSettings.toolTimeoutSeconds);
    supportsVision = config.settings.hasChatModelCapability(
      config.modelFullId,
      ChatModelCapability.vision,
    );
    drawImageStableReviewEnabled = stableImageRouteEnabled;

    apiCallTrace = trace?.startChild('调用AI API');
    apiCallTrace?.note(
      '连接',
      metadata: {
        'endpoint': config.providerApiBase.isNotEmpty
            ? config.providerApiBase
            : '后端网关',
        'model': config.modelFullId,
        'history': config.messages.length,
        'mode': flowSettings.mode.value,
        'effectiveImageRoute': effectiveImageRoute.value,
        'maxRounds': maxRounds,
        'fastFollowupBudget': fastImageRouteEnabled
            ? ChatSendApiRunner._maxFastFollowupRounds
            : 0,
        'modelTimeoutSec': flowSettings.modelTimeoutSeconds,
        'toolTimeoutSec': flowSettings.toolTimeoutSeconds,
      },
    );
    effectiveTurnId = (turnId != null && turnId.trim().isNotEmpty)
        ? turnId.trim()
        : 'turn_${DateTime.now().microsecondsSinceEpoch}';
    agent = agentClientFactory(modelTimeout);

    var provider = 'openai';
    final idx = config.modelFullId.indexOf(':');
    if (idx > 0) provider = config.modelFullId.substring(0, idx);
    adapter = ProviderAdapterFactory.getAdapter(
      provider,
      customConfig: config.customConfig,
      apiBaseUrl: config.providerApiBase,
    );
    shouldAttemptStreaming = config.presetStreamResponse ?? enableStreaming;
    remainingFastFollowupRounds = fastImageRouteEnabled
        ? ChatSendApiRunner._maxFastFollowupRounds
        : 0;
  }

  static const String _logTag = ChatSendApiRunner._logTag;
  static const bool _supportsTextToolFallback = true;

  final QuickJsPresetRuntime? presetRuntime;
  final ApiConfig config;
  final String sessionId;
  final String? userText;
  final List<Plugin> effectivePlugins;
  late final List<AITool>? availableTools;
  late final ProviderChatRequestOptions? requestOptions;
  final TraceLogger? _trace;
  final int maxRounds;
  final void Function(String toolName)? onToolExecuting;
  final void Function(String delta)? onStreamTextDelta;
  final void Function()? onStreamTextReset;
  final void Function()? onStreamToolCallObserved;
  final void Function()? onStreamingFallback;
  final TraceContext? traceContext;

  late final List<Map<String, dynamic>> requestTools;
  late final CallFlowSettings flowSettings;
  late final bool fastImageRouteEnabled;
  late final Duration toolTimeout;
  late final bool supportsVision;
  late final bool drawImageStableReviewEnabled;
  late final TraceLogger? apiCallTrace;
  late final String effectiveTurnId;
  late final AgentApiClient agent;
  late final ProviderAdapter adapter;

  late bool shouldAttemptStreaming;
  late int remainingFastFollowupRounds;
  final allToolEvents = <PluginEvent>[];
  final allToolAudioResults = <ToolAudioResult>[];
  final allToolContents = <PluginContent>[];
  final allToolCalls = <ToolCall>[];
  final allRawToolResults = <ToolResult>[];
  final executedFallbackCallSignatures = <String>{};
  final preToolNarrativeTexts = <String>[];
  var pendingStableReviewImages = <PluginImageContent>[];
  var executedAnyTool = false;
  var lastRoundIndex = 1;
  var runningLength = 0;
  SendMessageRichResult? lastRich;
  TraceLogger? roundTrace;
  TraceLogger? toolTrace;
  var useFastToolRoute = false;

  List<Map<String, dynamic>> get initialMessages =>
      List<Map<String, dynamic>>.from(config.messages);

  // Per-round preset output state (reset at the start of every round) ----

  var _streamRaw = '';
  var _streamOutput = '';
  var _scriptStreamFilter = _VisibleAssistantStreamFilter();
  Future<void> _pendingOutput = Future.value();
  Object? _outputError;
  Timer? _transportTimer;
  List<ToolCall> Function()? _transportSnapshot;
  var _transportDirty = false;
  var _transportPreviewFingerprint = '';

  void _resetRoundOutputState() {
    _pendingOutput = Future.value();
    _outputError = null;
    _streamRaw = '';
    _streamOutput = '';
    _scriptStreamFilter = _VisibleAssistantStreamFilter();
    _transportTimer?.cancel();
    _transportTimer = null;
    _transportSnapshot = null;
    _transportDirty = false;
    _transportPreviewFingerprint = '';
  }

  void _publishScriptOutput(String text) {
    if (!text.startsWith(_streamOutput)) {
      onStreamTextReset?.call();
      _streamOutput = '';
      _scriptStreamFilter = _VisibleAssistantStreamFilter();
    }
    final delta = _scriptStreamFilter.consume(
      text.substring(_streamOutput.length),
    );
    _streamOutput = text;
    if (delta.isNotEmpty) onStreamTextDelta?.call(delta);
  }

  // Coalesce transport snapshots before crossing the QuickJS boundary.
  void _flushTransportPreview() {
    _transportTimer?.cancel();
    _transportTimer = null;
    if (!_transportDirty) return;
    _transportDirty = false;
    final preset = presetRuntime!;
    final text = _streamRaw;
    final names = preset.transportTools
        .map((t) => (t['function'] as Map)['name'])
        .toSet();
    final calls = [
      for (final call in _transportSnapshot?.call() ?? <ToolCall>[])
        if (names.contains(call.name))
          {
            'id': call.id,
            'name': call.name,
            'arguments': call.arguments,
            if (call.rawArguments != null) 'rawArguments': call.rawArguments,
          },
    ];
    final fingerprint = jsonEncode([text, calls]);
    if (fingerprint == _transportPreviewFingerprint) return;
    _transportPreviewFingerprint = fingerprint;
    _pendingOutput = _pendingOutput.then((_) async {
      if (_outputError != null) return;
      try {
        _publishScriptOutput(await preset.update(text, calls: calls));
      } catch (error) {
        _outputError = error;
      }
    });
  }

  void _scheduleTransportPreview() {
    _transportDirty = true;
    _transportTimer ??= Timer(
      const Duration(milliseconds: 50),
      _flushTransportPreview,
    );
  }

  // ① ------------------------------------------------------------------

  @override
  bool get canRecoverOverflow => config.runtimeContext != null;

  @override
  Future<kernel.PreparedRound> prepare(
    List<Map<String, dynamic>> running,
    kernel.PrepareMode mode,
    kernel.TurnContext ctx,
  ) async {
    var current = running;
    if (mode == kernel.PrepareMode.recovery) {
      // 只重试当前模型请求；工具执行在这个循环之外。
      onStreamingFallback?.call();
      current = await config.runtimeContext!.prepare(current, force: true);
      final request = await presetRuntime?.prepare(current) ?? current;
      _transportSnapshot = null;
      _transportPreviewFingerprint = '';
      _streamRaw = '';
      _streamOutput = '';
      _scriptStreamFilter = _VisibleAssistantStreamFilter();
      runningLength = current.length;
      return kernel.PreparedRound(running: current, request: request);
    }
    if (!supportsVision) {
      current = _sanitizeMessagesForNonVisionModel(current);
    }
    current = await resolveModelMedia(current);
    current = await config.runtimeContext?.prepare(current) ?? current;
    final request = await presetRuntime?.prepare(current) ?? current;
    _resetRoundOutputState();
    runningLength = current.length;

    lastRoundIndex = ctx.round;
    roundTrace = apiCallTrace?.startChild('第 ${ctx.round} 轮 API 调用');
    roundTrace?.note(
      '请求',
      metadata: {
        'round': ctx.round,
        'mode': flowSettings.mode.value,
        'messagesCount': current.length,
      },
    );
    return kernel.PreparedRound(running: current, request: request);
  }

  // ② ------------------------------------------------------------------

  @override
  Future<kernel.AssistantTurn> send(
    kernel.PreparedRound prepared,
    kernel.TurnContext ctx,
  ) async {
    try {
      final rich = await _attempt(prepared.request, ctx.round);
      return kernel.AssistantTurn(
        text: rich.text,
        toolCalls: [for (final call in rich.toolCalls) _toKernelCall(call)],
        hiddenThoughtParts: rich.hiddenThoughtParts,
        raw: rich,
      );
    } catch (error, stack) {
      if (isContextOverflow(error)) {
        throw kernel.KernelContextOverflow(
          '$error',
          cause: error,
          causeStackTrace: stack,
        );
      }
      rethrow;
    }
  }

  /// One request attempt in the legacy order: budget check → preset reset →
  /// send (streaming with fallback) → drain preset output.
  Future<SendMessageRichResult> _attempt(
    List<Map<String, dynamic>> requestMessages,
    int round,
  ) async {
    final preset = presetRuntime;
    if (preset != null &&
        config.requestInputTokenLimit != null &&
        renderedContextTokens(requestMessages, requestTools) >=
            config.requestInputTokenLimit!) {
      throw StateError('上下文超限：预设处理后的消息与工具定义超过本轮预算');
    }
    await preset?.reset(shouldAttemptStreaming);

    Future<SendMessageRichResult> sendRichNonStream() => agent.sendMessageRich(
      agentId: 'default',
      sessionId: sessionId,
      modelFullId: config.modelFullId,
      messages: requestMessages,
      userText: round == 1 ? (userText ?? '') : '',
      temperature: config.effectiveTemperature,
      topP: config.modelTopP,
      token: config.settings.backendApiKey,
      toolPrefs: config.toolPrefs,
      providerApiBase: config.providerApiBase,
      providerApiKey: config.providerApiKey,
      customConfig: config.customConfig,
      tools: requestTools.isEmpty ? null : requestTools,
      requestOptions: requestOptions,
      trace: roundTrace,
      turnId: effectiveTurnId,
      roundIndex: round,
      traceId: traceContext?.traceId,
    );

    SendMessageRichResult rich;
    if (shouldAttemptStreaming) {
      final streamTextFilter = _VisibleAssistantStreamFilter();
      unawaited(
        StreamMonitorService.recordAttempt(
          modelFullId: config.modelFullId,
          round: round,
        ),
      );
      final hasTransport = preset?.transportTools.isNotEmpty ?? false;
      try {
        rich = await agent.sendMessageRichStream(
          agentId: 'default',
          sessionId: sessionId,
          modelFullId: config.modelFullId,
          messages: requestMessages,
          userText: round == 1 ? (userText ?? '') : '',
          temperature: config.effectiveTemperature,
          topP: config.modelTopP,
          token: config.settings.backendApiKey,
          toolPrefs: config.toolPrefs,
          providerApiBase: config.providerApiBase,
          providerApiKey: config.providerApiKey,
          customConfig: config.customConfig,
          tools: requestTools.isEmpty ? null : requestTools,
          requestOptions: requestOptions,
          onTextDelta: (delta) {
            if (hasTransport) {
              _streamRaw += delta;
              _scheduleTransportPreview();
              return;
            }
            if (preset != null) {
              _pendingOutput = _pendingOutput.then((_) async {
                if (_outputError != null) return;
                try {
                  _publishScriptOutput(
                    await preset.update(_streamRaw += delta),
                  );
                } catch (e) {
                  _outputError = e;
                }
              });
              return;
            }
            if (onStreamTextDelta == null || delta.isEmpty) return;
            final visibleDelta = streamTextFilter.consume(delta);
            if (visibleDelta.isEmpty) return;
            onStreamTextDelta!(visibleDelta);
          },
          onToolCallsDetected: onStreamToolCallObserved,
          onToolCallProgress: hasTransport
              ? (snapshot) {
                  _transportSnapshot = snapshot;
                  _scheduleTransportPreview();
                }
              : null,
          trace: roundTrace,
          turnId: effectiveTurnId,
          roundIndex: round,
          traceId: traceContext?.traceId,
        );
        unawaited(
          StreamMonitorService.recordSuccess(
            modelFullId: config.modelFullId,
            round: round,
          ),
        );
      } catch (e) {
        _flushTransportPreview();
        await _pendingOutput;
        if (_outputError != null) throw _outputError!;
        if (isContextOverflow(e)) rethrow;
        shouldAttemptStreaming = false;
        onStreamingFallback?.call();
        final failureReason = StreamMonitorService.classifyError(e);
        unawaited(
          StreamMonitorService.recordFallback(
            modelFullId: config.modelFullId,
            error: e,
            reason: failureReason,
            round: round,
          ),
        );
        AppLogger.warning(
          _logTag,
          '流式调用失败，回退整段响应',
          metadata: {
            'round': round,
            'model': config.modelFullId,
            'reason': failureReason.value,
            'error': e.toString(),
          },
        );
        await preset?.reset(false);
        if (preset != null) {
          onStreamTextReset?.call();
          _streamOutput = '';
          _streamRaw = '';
          _scriptStreamFilter = _VisibleAssistantStreamFilter();
        }
        _transportSnapshot = null;
        rich = await sendRichNonStream();
      } finally {
        _flushTransportPreview();
        await _pendingOutput;
      }
    } else {
      rich = await sendRichNonStream();
    }

    await _pendingOutput;
    if (_outputError != null) throw _outputError!;
    return rich;
  }

  // ③ ------------------------------------------------------------------

  @override
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
      );
    }
    lastRich = rich;
    roundTrace?.note(
      '响应',
      metadata: {
        'textLength': rich.text.length,
        'toolCalls': rich.toolCalls.length,
      },
    );
    return kernel.AssistantTurn(
      text: rich.text,
      toolCalls: [for (final call in rich.toolCalls) _toKernelCall(call)],
      hiddenThoughtParts: rich.hiddenThoughtParts,
      raw: rich,
      presetConsumed: consumedPresetOutput,
    );
  }

  // ④ ------------------------------------------------------------------

  @override
  kernel.ResolvedToolCalls resolve(
    kernel.AssistantTurn turn,
    kernel.TurnContext ctx,
  ) {
    final rich = lastRich!;
    var currentToolCalls = List<ToolCall>.from(rich.toolCalls);
    var usesFallbackToolCalls = false;
    if (currentToolCalls.isEmpty &&
        _supportsTextToolFallback &&
        !turn.presetConsumed) {
      final fallbackToolCalls = _extractFallbackToolCalls(rich.text);
      if (fallbackToolCalls.isNotEmpty) {
        final deduped = <ToolCall>[];
        for (final call in fallbackToolCalls) {
          final signature = _buildToolCallSignature(call);
          if (executedFallbackCallSignatures.contains(signature)) continue;
          executedFallbackCallSignatures.add(signature);
          deduped.add(call);
        }
        if (deduped.isNotEmpty) {
          currentToolCalls = deduped;
          usesFallbackToolCalls = true;
          AppLogger.info(
            _logTag,
            'Parsed text tool call fallback',
            metadata: {
              'round': ctx.round,
              'count': deduped.length,
              'names': deduped.map((t) => t.name).toList(),
            },
          );
        } else {
          AppLogger.warning(
            _logTag,
            'Duplicate fallback tool call skipped',
            metadata: {'round': ctx.round},
          );
        }
      }
    }
    return kernel.ResolvedToolCalls([
      for (final call in currentToolCalls) _toKernelCall(call),
    ], usesFallback: usesFallbackToolCalls);
  }

  // ⑤ ------------------------------------------------------------------

  @override
  Future<void> beforeTools(
    kernel.AssistantTurn turn,
    kernel.ResolvedToolCalls calls,
    kernel.TurnContext ctx,
  ) async {
    final round = ctx.round;
    final currentToolCalls = _toolCallsOf(calls);
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
    if (roundNarrativeText.isNotEmpty &&
        !_looksLikeToolInstructionText(roundNarrativeText)) {
      preToolNarrativeTexts.add(roundNarrativeText);
    }

    onStreamToolCallObserved?.call();

    useFastToolRoute = _shouldUseFastToolRoute(
      fastModeEnabled: fastImageRouteEnabled,
      toolCalls: currentToolCalls,
    );
    if (fastImageRouteEnabled && !useFastToolRoute) {
      AppLogger.info(
        _logTag,
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
        _logTag,
        'Stable draw_image approved for delivery',
        metadata: {'round': round, 'count': pendingStableReviewImages.length},
      );
      pendingStableReviewImages = <PluginImageContent>[];
      return;
    }

    if (requestsRedraw) {
      AppLogger.info(
        _logTag,
        'Stable draw_image rejected, regenerate',
        metadata: {'round': round},
      );
      pendingStableReviewImages = <PluginImageContent>[];
      return;
    }

    if (toolCalls.isEmpty) {
      AppLogger.info(
        _logTag,
        'Stable draw_image not delivered by model',
        metadata: {'round': round},
      );
      pendingStableReviewImages = <PluginImageContent>[];
    }
  }

  // ⑦ ------------------------------------------------------------------

  @override
  kernel.BatchMode modeFor(
    List<kernel.KernelToolCall> calls,
    kernel.TurnContext ctx,
  ) => useFastToolRoute ? kernel.BatchMode.parallel : kernel.BatchMode.serial;

  @override
  Future<kernel.KernelToolResult> executeOne(
    kernel.KernelToolCall call,
    kernel.TurnContext ctx,
  ) async {
    final outcome = await _executeToolCall(
      toolCall: call.origin! as ToolCall,
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
      round: ctx.round,
      useFastToolRoute: useFastToolRoute,
    );
    return kernel.KernelToolResult(
      callId: outcome.toolResult.toolCallId,
      name: outcome.toolResult.name,
      content: outcome.toolResult.result,
      payload: outcome,
    );
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
          _logTag,
          'Stable draw_image result held for review',
          metadata: {'count': pendingStableReviewImages.length},
        );
      } else {
        allToolContents.addAll(outcome.imageContents);
      }
    }
  }

  // ⑧ ------------------------------------------------------------------

  List<ToolResult> _roundToolResults = const [];

  @override
  Future<kernel.TurnVerdict> afterTools(
    kernel.AssistantTurn turn,
    kernel.ResolvedToolCalls calls,
    List<kernel.KernelToolResult> results,
    kernel.TurnContext ctx,
  ) async {
    final round = ctx.round;
    final currentToolCalls = _toolCallsOf(calls);
    final toolOutcomes = [
      for (final result in results) result.payload! as _ToolExecutionOutcome,
    ];
    final toolResults = <ToolResult>[];
    for (final outcome in toolOutcomes) {
      _collectToolOutcome(outcome, toolResults);
    }
    _roundToolResults = toolResults;
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

    final shouldContinueFastFollowup =
        useFastToolRoute && toolOutcomes.any((o) => o.isAsyncAcceptedDrawImage);

    if (useFastToolRoute && !shouldContinueFastFollowup) {
      AppLogger.info(_logTag, '快速生图路由停止后续模型轮次', metadata: {'round': round});
      roundTrace?.end(additionalMessage: 'fast mode stop');
      return const kernel.TurnVerdict.stop('fast mode stop');
    }

    if (round == maxRounds) {
      if (useFastToolRoute && shouldContinueFastFollowup) {
        AppLogger.info(
          _logTag,
          '快速生图路由达到补充轮次上限',
          metadata: {'round': round, 'maxRounds': maxRounds},
        );
        roundTrace?.end(additionalMessage: 'fast follow-up max round');
      } else {
        AppLogger.warning(
          _logTag,
          '达到最大回合数',
          metadata: {'maxRounds': maxRounds},
        );
        roundTrace?.end(additionalMessage: '达到最大回合数');
      }
      return const kernel.TurnVerdict.stop('maxRounds');
    }

    if (shouldContinueFastFollowup) {
      if (remainingFastFollowupRounds <= 0) {
        AppLogger.info(
          _logTag,
          '快速生图路由达到补充轮次上限',
          metadata: {
            'round': round,
            'maxRounds': ChatSendApiRunner._maxFastFollowupRounds + 1,
          },
        );
        roundTrace?.end(additionalMessage: 'fast follow-up max round');
        return const kernel.TurnVerdict.stop('fast follow-up max round');
      }
      remainingFastFollowupRounds -= 1;
    }
    return const kernel.TurnVerdict.proceed();
  }

  // ⑨ ------------------------------------------------------------------

  @override
  Future<List<Map<String, dynamic>>> encode(
    kernel.AssistantTurn turn,
    kernel.ResolvedToolCalls calls,
    List<kernel.KernelToolResult> results,
    kernel.TurnContext ctx,
  ) async {
    final assistantMessage = calls.usesFallback
        ? _buildFallbackAssistantMessageForToolCalls(
            _toolCallsOf(calls),
            adapter.name,
          )
        : _buildAssistantMessageFromRich(lastRich!, adapter.name);
    final toolResultMessages = adapter.buildToolResultMessages(
      assistantMessage: assistantMessage,
      toolResults: _roundToolResults,
    );
    final normalizedToolResultMessages = !supportsVision
        ? _sanitizeMessagesForNonVisionModel(toolResultMessages)
        : toolResultMessages;
    var nextRoundMessages = List<Map<String, dynamic>>.from(
      normalizedToolResultMessages,
    );
    if (presetRuntime != null) {
      // Gemini adapters return native model/parts messages. The preset host
      // receives canonical roles while preserving the structured parts.
      nextRoundMessages = [
        for (final message in nextRoundMessages)
          if (message['role'] == 'model')
            {...message, 'role': 'assistant'}
          else
            message,
      ];
    }
    if (drawImageStableReviewEnabled && pendingStableReviewImages.isNotEmpty) {
      final reviewMessages = await _buildStableDrawImageReviewMessages(
        pendingStableReviewImages,
      );
      if (reviewMessages.isNotEmpty) {
        nextRoundMessages = [...nextRoundMessages, ...reviewMessages];
      }
    }

    roundTrace?.note(
      '追加工具结果',
      metadata: {
        'newMessagesCount': nextRoundMessages.length,
        'totalMessages': runningLength + nextRoundMessages.length,
        'pendingStableReviewImages': pendingStableReviewImages.length,
      },
    );
    roundTrace?.end(additionalMessage: 'continue next round');
    return nextRoundMessages;
  }

  // Result processing (outside the loop, inside the runner) ---------------

  Future<ApiCallResult> finalize(ChatSendApiRunner legacy) async {
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
    final presetRegexResult = await ChatSendApiRunner._presetRegexProcessor
        .applyToDisplayText(
          text: finalAssistantText,
          scripts: config.presetRegexScripts,
          authorized: config.presetRegexAuthorized,
        );
    finalAssistantText = presetRegexResult.text;
    apiCallTrace?.note(
      '完成',
      metadata: {
        'textLength': finalAssistantText.length,
        'toolResults': lastRich?.toolResults.length ?? 0,
      },
    );
    apiCallTrace?.end(additionalMessage: 'API调用成功');
    final pluginTrace = _trace?.startChild('运行插件');
    final pluginResult = await legacy._processResponseWithPlugins(
      effectivePlugins,
      finalAssistantText,
    );
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
    );
  }

  static kernel.KernelToolCall _toKernelCall(ToolCall call) =>
      kernel.KernelToolCall(
        id: call.id,
        name: call.name,
        arguments: call.arguments,
        rawArguments: call.rawArguments,
        origin: call,
      );

  static List<ToolCall> _toolCallsOf(kernel.ResolvedToolCalls calls) => [
    for (final call in calls.calls) call.origin! as ToolCall,
  ];
}
