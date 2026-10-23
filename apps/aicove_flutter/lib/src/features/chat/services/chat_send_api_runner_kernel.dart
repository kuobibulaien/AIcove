part of 'chat_send_api_runner.dart';

/// [ApiRunner] backed by the agent kernel (ADR0064, batch 1).
///
/// Shared execution pipeline. Chat product policies are separate stage adapters;
/// the preset runtime stays in the run scope until result processing completes.
class KernelApiRunner implements ApiRunner {
  const KernelApiRunner()
    : _agentClientFactory = ChatSendApiRunner._defaultAgentClientFactory,
      _scopeFactory = kernel.KernelScope.new,
      _openPresetRuntime = null,
      _richToolOutput = true;

  /// [scopeFactory] and [openPresetRuntime] let tests observe when the run
  /// scope is released and whether the preset runtime is still open;
  /// [openPresetRuntime] takes precedence over the configured service.
  KernelApiRunner.withAgentClientFactory({
    required AgentApiClient Function(Duration timeout) agentClientFactory,
    kernel.KernelScope Function() scopeFactory = kernel.KernelScope.new,
    PresetRuntimeOpener? openPresetRuntime,
  }) : _agentClientFactory = agentClientFactory,
       _scopeFactory = scopeFactory,
       _openPresetRuntime = openPresetRuntime,
       _richToolOutput = true;

  // Historical callers consume text-only tool projections, even with vision.
  KernelApiRunner._persistentToolOutput(this._agentClientFactory)
    : _scopeFactory = kernel.KernelScope.new,
      _openPresetRuntime = null,
      _richToolOutput = false;

  static const String _logTag = 'KernelApiRunner';

  final _AgentClientFactory _agentClientFactory;
  final bool _richToolOutput;
  final kernel.KernelScope Function() _scopeFactory;
  final PresetRuntimeOpener? _openPresetRuntime;

  /// Loop diagnostics kept in the app log (batch 2 plan §3.8): only names
  /// and counts, never message or argument text.
  static Future<void> _recordDiagnostics(kernel.KernelEvent event) async {
    if (event is kernel.FinishReasonMismatch) {
      AppLogger.warning(
        _logTag,
        '结束原因与工具调用不一致；截断调用不执行',
        metadata: {
          'round': event.round,
          'finishReason': event.finishReason.name,
          'toolCalls': event.toolCalls,
        },
      );
    }
  }

  @override
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    required List<PluginResponseProcessor> responseProcessors,
    List<AITool>? availableTools,
    String? turnId,
    TraceLogger? trace,
    void Function(String toolName)? onToolExecuting,
    bool enableStreaming = false,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
    TraceContext? traceContext,
    kernel.KernelCancellation? cancellation,
  }) async {
    final scope = _scopeFactory();
    try {
      // The preset runtime comes from the tavern compatibility plugin's
      // service, fixed into the config at prepare.
      final openPresetRuntime =
          _openPresetRuntime ??
          config.openPresetRuntime ??
          QuickJsPresetRuntime.open;
      final presetRuntime = config.presetScript == null
          ? null
          : await openPresetRuntime(config.presetScript!);
      if (presetRuntime != null) scope.addCloser(presetRuntime.close);
      final results = config.toolResultStore ?? ToolResultStore.shared;
      final owner = config.toolResultOwner ?? sessionId;
      final reader = results.reader(owner);
      final existingTools = availableTools ?? config.boundTools;
      final hasTools = ToolResultStore.wantsReader([
        ...?existingTools?.map((t) => t.name),
        for (final s in config.tools ?? const <Map<String, dynamic>>[])
          '${(s['function'] as Map?)?['name']}',
      ]);
      final tools = [
        ...?existingTools,
        if (hasTools &&
            !(existingTools?.any(
                  (t) => t.name == ToolResultStore.readToolName,
                ) ??
                false))
          reader,
      ];
      final hasReaderSchema =
          config.tools?.any(
            (s) =>
                (s['function'] as Map?)?['name'] ==
                ToolResultStore.readToolName,
          ) ??
          false;
      final readerIsDirect =
          existingTools
              ?.where((t) => t.name == ToolResultStore.readToolName)
              .firstOrNull
              ?.exposure !=
          ToolExposure.codemode;
      final effectiveConfig = hasTools && !hasReaderSchema && readerIsDirect
          ? config.copyWith(tools: [...?config.tools, reader.toOpenAISchema()])
          : config;
      final run = _KernelRun(
        presetRuntime: presetRuntime,
        richToolOutput: _richToolOutput,
        config: effectiveConfig,
        sessionId: sessionId,
        userText: userText,
        responseProcessors: responseProcessors,
        availableTools: tools,
        turnId: turnId,
        trace: trace,
        onToolExecuting: onToolExecuting,
        enableStreaming: enableStreaming,
        onStreamTextDelta: onStreamTextDelta,
        onStreamTextReset: onStreamTextReset,
        onStreamToolCallObserved: onStreamToolCallObserved,
        onStreamingFallback: onStreamingFallback,
        traceContext: traceContext,
        agentClientFactory: _agentClientFactory,
      );
      final product = _ChatProductStages(run);
      final loop = kernel.AgentLoop(
        stages: kernel.StagePipeline(
          preparer: run,
          model: run,
          unpacker: product,
          resolver: const kernel.NativeToolCallResolver(),
          preTool: product,
          tools: _RecordedTools(
            _gated(run, config.toolPolicy),
            config,
            results,
            owner,
          ),
          postTool: product,
          encoder: run,
        ),
        observers: const [_recordDiagnostics],
        onTranscript: config.onTranscript,
      );
      config.onRunReady?.call(loop.steer);
      final kernel.AgentLoopResult result;
      try {
        result = await loop.run(
          run.initialMessages,
          cancellation:
              cancellation ??
              config.cancellation ??
              RequestControl.cancellation,
        );
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
      return await run.finalize(
        status: result.stopReason == kernel.KernelStopReason.waitingForUser
            ? ApiRunStatus.waitingForUser
            : result.lastTurn?.finishReason == kernel.FinishReason.length
            ? ApiRunStatus.truncated
            : ApiRunStatus.completed,
        runningMessages: result.runningMessages,
        stopReason: result.stopReason?.wireValue,
      );
    } finally {
      // After result processing: plugins and the preset runtime stay usable
      // until the ApiCallResult is built.
      await scope.dispose();
    }
  }
}

/// Records each settled call before the next tool starts, including denials.
/// Preservation runs outside redaction so stored output obeys the same policy.
class _RecordedTools implements kernel.ToolBatchExecutor {
  _RecordedTools(this.inner, this.config, this.store, this.owner);
  final kernel.ToolBatchExecutor inner;
  final ApiConfig config;
  final ToolResultStore store;
  final String owner;

  @override
  kernel.BatchMode modeFor(
    List<kernel.KernelToolCall> calls,
    kernel.TurnContext ctx,
  ) => config.onToolStep != null
      ? kernel.BatchMode.serial
      : inner.modeFor(calls, ctx);

  @override
  Future<kernel.KernelToolResult> executeOne(
    kernel.KernelToolCall call,
    kernel.TurnContext ctx,
  ) async {
    final watch = Stopwatch()..start();
    var result = await inner.executeOne(call, ctx);
    // A denied/invalid script never reaches QuickJS, but its stored block
    // still follows the same script-result contract as an executed script.
    if (call.name == 'codemode' &&
        !result.content.startsWith('Script completed') &&
        !result.content.startsWith('Script failed')) {
      final content =
          'Script failed\nWall time ${(watch.elapsedMicroseconds / 1000000).toStringAsFixed(1)} seconds\nOutput:\nScript error:\n${result.content}';
      result = kernel.KernelToolResult(
        callId: result.callId,
        name: result.name,
        content: content,
        isError: true,
        payload: _ToolExecutionOutcome(
          toolResult: ToolResult(
            toolCallId: result.callId,
            name: result.name,
            result: content,
            isError: true,
            structured: const {'codemodeCalls': <Map<String, dynamic>>[]},
          ),
        ),
      );
    }
    final text = call.name == 'codemode'
        ? result.content
        : await store.preserve(owner, result.content);
    final preserved = kernel.KernelToolResult(
      callId: result.callId,
      name: result.name,
      content: text,
      isError: result.isError,
      images: result.images,
      payload: result.payload,
      outputRewritten: result.outputRewritten,
      terminationReason: result.terminationReason,
    );
    await config.onToolStep?.call(
      call.origin! as ToolCall,
      _KernelRun._outcomeOf(preserved).toolResult,
    );
    return preserved;
  }
}

/// Applies the run's tool policy to ⑦: redaction inside, the gate outside, so
/// a denied call never runs and an allowed one is redacted before the model
/// sees it. Without a policy ⑦ is the run itself, as before.
kernel.ToolBatchExecutor _gated(_KernelRun run, AgentToolPolicy? policy) {
  policy ??= const AgentToolPolicy(
    authorization: AgentToolAuthorization.allowAll,
  );
  final redactor = policy.redactor;
  return kernel.GatedToolExecutor(
    redactor == null ? run : kernel.RedactingToolExecutor(run, redactor),
    gate: policy.gate,
    effectOf: run.effectOf,
    requiresHumanApprovalOf: (call) =>
        run.availableTools?.any(
          (tool) => tool.name == call.name && tool.requiresHumanApproval,
        ) ??
        false,
    approvals: policy.approvals,
    approvalTimeout: policy.approvalTimeout,
  );
}

/// Request/tool adapters and single-owner state for one run. Product policies
/// live in chat_run_product_stages.dart; only AgentLoop controls iteration.
class _KernelRun
    implements
        kernel.RoundPreparer,
        kernel.ModelPort,
        kernel.ToolBatchExecutor,
        kernel.ContinuationEncoder {
  _KernelRun({
    required this.presetRuntime,
    required this.richToolOutput,
    required this.config,
    required this.sessionId,
    required this.userText,
    required this.responseProcessors,
    required List<AITool>? availableTools,
    required String? turnId,
    required TraceLogger? trace,
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
      availableTools = [...?availableTools];
    }
    final nonDirect = {
      for (final tool in availableTools ?? const <AITool>[])
        if (tool.exposure != ToolExposure.direct) tool.name,
    };
    requestTools = [
      for (final schema in [...?config.tools, ...?preset?.tools])
        if (!nonDirect.contains((schema['function'] as Map)['name'])) schema,
    ];
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
          inputSchema: Map<String, dynamic>.from(
            definition['parameters'] as Map? ?? const {},
          ),
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
  }

  static const String _logTag = ChatSendApiRunner._logTag;

  final PresetScriptRuntime? presetRuntime;
  final bool richToolOutput;
  final ApiConfig config;
  final String sessionId;
  final String? userText;
  final List<PluginResponseProcessor> responseProcessors;
  late final List<AITool>? availableTools;
  late final ProviderChatRequestOptions? requestOptions;
  final TraceLogger? _trace;
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
  final allToolEvents = <PluginEvent>[];
  final allToolAudioResults = <ToolAudioResult>[];
  final allToolContents = <PluginContent>[];
  final allToolCalls = <ToolCall>[];
  final allRawToolResults = <ToolResult>[];

  final preToolNarrativeTexts = <String>[];
  final toolRoundDrafts =
      <({String narrative, String reasoning, List<String> toolCallIds})>[];
  var pendingStableReviewImages = <PluginImageContent>[];
  var executedAnyTool = false;
  var lastRoundIndex = 1;
  var runningLength = 0;
  SendMessageRichResult? lastRich;
  final roundReasonings = <String>[];
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
  ) => RequestControl.run(ctx.cancellation, () => _prepare(running, mode, ctx));

  Future<kernel.PreparedRound> _prepare(
    List<Map<String, dynamic>> running,
    kernel.PrepareMode mode,
    kernel.TurnContext ctx,
  ) async {
    var current = running;
    if (mode == kernel.PrepareMode.initial &&
        drawImageStableReviewEnabled &&
        pendingStableReviewImages.isNotEmpty) {
      current = [
        ...current,
        ...await _buildStableDrawImageReviewMessages(pendingStableReviewImages),
      ];
    }
    if (mode == kernel.PrepareMode.recovery) {
      // 只重试当前模型请求；工具执行在这个循环之外。
      onStreamingFallback?.call();
      current = await config.runtimeContext!.prepare(current, force: true);
      final budgeted = ToolMedia.wire(current, strip: false);
      final request = ToolMedia.wire(
        await presetRuntime?.prepare(budgeted) ?? budgeted,
      );
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
    final budgeted = ToolMedia.wire(current, strip: false);
    final request = ToolMedia.wire(
      await presetRuntime?.prepare(budgeted) ?? budgeted,
    );
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
      final rich = await retryModelRound(
        cancellation: ctx.cancellation,
        send: () => _attempt(prepared.request, ctx.round),
        onRetry: (attempt, delay) {
          onStreamTextReset?.call();
          _resetRoundOutputState();
          AppLogger.warning(
            _logTag,
            'Retrying current model round',
            metadata: {
              'round': ctx.round,
              'attempt': attempt,
              'delayMs': delay.inMilliseconds,
            },
          );
        },
      );
      return kernel.AssistantTurn(
        text: rich.text,
        toolCalls: [for (final call in rich.toolCalls) _toKernelCall(call)],
        hiddenThoughtParts: rich.hiddenThoughtParts,
        raw: rich,
        finishReason: rich.finishReason,
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
        RequestControl.cancellation?.throwIfCancelled();
        _flushTransportPreview();
        await _pendingOutput;
        if (_outputError != null) throw _outputError!;
        if (e is kernel.KernelCancelledException ||
            isTransientModelError(e) ||
            isContextOverflow(e))
          rethrow;
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

  // ⑦ ------------------------------------------------------------------

  /// Declared effect of the tool a call names; unknown tools count as
  /// external, the default for undeclared tools.
  kernel.ToolEffect effectOf(kernel.KernelToolCall call) {
    for (final tool in availableTools ?? const <AITool>[]) {
      if (tool.name == call.name) return tool.effect;
    }
    return kernel.ToolEffect.external;
  }

  @override
  kernel.BatchMode modeFor(
    List<kernel.KernelToolCall> calls,
    kernel.TurnContext ctx,
  ) =>
      calls.every((call) {
        final tool = _findToolByName(call.name, availableTools);
        return tool != null &&
            tool.terminationReason == null &&
            !tool.requiresHumanApproval &&
            (tool.concurrent ||
                tool.effect == kernel.ToolEffect.readDiagnostic ||
                tool.effect == kernel.ToolEffect.readPrivate);
      })
      ? kernel.BatchMode.parallel
      : kernel.BatchMode.serial;

  @override
  Future<kernel.KernelToolResult> executeOne(
    kernel.KernelToolCall call,
    kernel.TurnContext ctx,
  ) => _executeKernelTool(call, ctx, active: _nestedActive[call.id]);

  int _scriptCallSequence = 0;
  final _nestedActive = <String, bool Function()>{};

  Future<ToolOutput> _scriptTool(
    String name,
    Map<String, dynamic> args,
    bool Function() active,
    kernel.TurnContext ctx, {
    kernel.KernelCancellation? cancellation,
    String? callId,
  }) async {
    if (!active() || ctx.cancellation.isCancelled)
      throw StateError('Script invocation closed');
    if (name == 'codemode')
      throw StateError('Recursive codemode is not available');
    if (!(availableTools?.any((t) => t.name == name) ?? false))
      throw StateError('Tool unavailable: $name');
    final id = callId ?? 'script_${ctx.round}_${++_scriptCallSequence}';
    final call = kernel.KernelToolCall(
      id: id,
      name: name,
      arguments: args,
      origin: ToolCall(id: id, name: name, arguments: args),
    );
    final signal = cancellation ?? ctx.cancellation;
    final nestedCtx = kernel.TurnContext(
      round: ctx.round,
      cancellation: signal,
      emit: ctx.emit,
    );
    _nestedActive[id] = active;
    try {
      final result = await _gated(
        this,
        config.toolPolicy ??
            const AgentToolPolicy(
              authorization: AgentToolAuthorization.allowAll,
            ),
      ).executeOne(call, nestedCtx);
      final output = _outcomeOf(result).toolResult;
      return ToolOutput(
        text: output.result,
        isError: output.isError,
        images: output.images,
        structured: output.structured,
      );
    } finally {
      _nestedActive.remove(id);
    }
  }

  Future<kernel.KernelToolResult> _executeKernelTool(
    kernel.KernelToolCall call,
    kernel.TurnContext ctx, {
    bool Function()? active,
  }) async {
    final outcome = await _executeToolCall(
      toolCall: call.origin! as ToolCall,
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
      redactForLog: config.toolPolicy?.redactor?.redact ?? _unredacted,
      cancellation: ctx.cancellation,
      onProgress: (text) => config.onToolProgress?.call(
        call.name,
        config.toolPolicy?.redactor?.redact(text) ?? text,
      ),
      isCancelled: () =>
          ctx.cancellation.isCancelled || !(active?.call() ?? true),
      stateOwner: config.toolResultOwner ?? sessionId,
      scriptTools: ScriptToolAccess(
        List.unmodifiable(availableTools ?? const <AITool>[]),
        (name, args, valid) => _scriptTool(
          name,
          args,
          () => valid() && (active?.call() ?? true),
          ctx,
        ),
        invokeControlled: (name, args, valid, signal, id) => _scriptTool(
          name,
          args,
          () => valid() && (active?.call() ?? true),
          ctx,
          cancellation: signal,
          callId: id,
        ),
      ),
      invocationOwnsDeadline: active != null,
      richOutput: richToolOutput,
      supportsVision: supportsVision,
    );
    return kernel.KernelToolResult(
      callId: outcome.toolResult.toolCallId,
      name: outcome.toolResult.name,
      content: outcome.toolResult.result,
      payload: outcome,
      images: outcome.toolResult.images,
      isError: outcome.toolResult.isError,
      terminationReason: outcome.toolResult.isError
          ? null
          : _findToolByName(call.name, availableTools)?.terminationReason,
    );
  }

  /// The model sees only [kernel.KernelToolResult.content]: a gate or a
  /// redactor may have replaced it, and a call the gate stopped carries no
  /// execution outcome at all.
  static _ToolExecutionOutcome _outcomeOf(kernel.KernelToolResult result) {
    final payload = result.payload;
    final toolResult = ToolResult(
      toolCallId: result.callId,
      name: result.name,
      result: result.content,
      images: result.images,
      isError: result.isError,
      structured: payload is _ToolExecutionOutcome && !result.outputRewritten
          ? payload.toolResult.structured
          : null,
    );
    if (payload is! _ToolExecutionOutcome) {
      return _ToolExecutionOutcome(toolResult: toolResult);
    }
    return _ToolExecutionOutcome(
      toolResult: toolResult,
      audioResult: payload.audioResult,
      imageContents: result.outputRewritten ? const [] : payload.imageContents,
      isAsyncAcceptedDrawImage: payload.isAsyncAcceptedDrawImage,
    );
  }

  // ⑨ ------------------------------------------------------------------

  @override
  Future<List<Map<String, dynamic>>> encode(
    kernel.AssistantTurn turn,
    kernel.ResolvedToolCalls calls,
    List<kernel.KernelToolResult> results,
    kernel.TurnContext ctx,
  ) async {
    final assistantMessage = _buildAssistantMessageFromRich(
      lastRich!,
      adapter.name,
    );
    if (calls.isEmpty)
      return [
        {...assistantMessage, 'role': 'assistant'},
      ];
    final toolResultMessages = adapter.buildToolResultMessages(
      assistantMessage: assistantMessage,
      toolResults: [
        for (final result in results) _outcomeOf(result).toolResult,
      ],
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
