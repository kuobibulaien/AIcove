import '../../observability/model_request_ledger.dart';
import 'dart:convert';
import '../../workspace/application/codemode_declarations.dart';
import '../../workspace/application/tool_search.dart';
import '../../context/application/runtime_context_service.dart';
import '../../context/domain/context_window_policy.dart';
import '../../context/domain/context_summary.dart';
import '../../context/data/background_context_summarizer.dart';
import '../../plugins/data/tool_result_store.dart';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show KernelCancellation, ToolEffect, KernelStopReason;

import '../../../core/api/providers/provider_adapter.dart'
    show ToolCall, ToolResult;
import '../../../core/models/message_block.dart';
import '../../agent_plugins/tool_policy.dart';
import '../../agent_context/domain/agent_runtime_contracts.dart';
import '../../background_agent/background_agent_service.dart';
import '../../chat/services/chat_types.dart';
import '../../chat/services/provider_key_failure.dart';
import '../../plugins/domain/handlers/ai_tool.dart';
import '../../settings/app_settings.dart';
import '../../workspace/application/workspace_toolset.dart';

/// What the errand agent may use in one run, already resolved by the single
/// rule role grant ∩ preset ∩ enabled ∩ present on this device (ADR0087 §1).
class TaskAgentCapabilities {
  const TaskAgentCapabilities({
    this.tools = const [],
    this.prompts = const {},
    this.toolOwners = const {},
    this.workspaces,
    this.toolPolicyFactory,
  });

  /// Active role-selected backend and assistant tools, excluding workspaces.
  final List<AITool> tools;
  final Map<String, String> prompts;
  final Map<String, String> toolOwners;
  final WorkspaceToolset? workspaces;

  /// Builds the assistant gate with the actual model and channel of this run.
  final Future<AgentToolPolicy> Function(ApiConfig config)? toolPolicyFactory;

  bool get isEmpty =>
      prompts.isEmpty &&
      tools.isEmpty &&
      (workspaces == null || workspaces!.workspaceIds.isEmpty);
}

/// The errand agent preset (ADR0088 §3). Presets only narrow: null lists
/// mean no further limit beyond the role's grants.
class TaskAgentPreset {
  const TaskAgentPreset({
    this.modelRef,
    this.allowedPluginIds,
    this.allowedWorkspaceIds,
  });

  /// Null uses the default chat model.
  final String? modelRef;
  final Set<String>? allowedPluginIds;
  final Set<String>? allowedWorkspaceIds;
}

typedef TaskAgentExecutor =
    Future<ApiCallResult> Function({
      required ApiConfig config,
      required List<AITool> tools,
      required String sessionId,
      required KernelCancellation cancellation,
    });

/// Result of one run of the errand agent.
class TaskRunOutcome {
  const TaskRunOutcome({
    required this.summary,
    required this.question,
    this.detail,
    required this.artifacts,
    required this.processLog,
    this.status = ApiRunStatus.completed,
    this.stopReason,
    this.runningMessages = const [],
  });

  final List<Map<String, dynamic>> runningMessages;
  final ApiRunStatus status;
  final String? stopReason;
  final String summary;

  /// Set when the agent asked the user something; the task then waits.
  final String? question;
  final String? detail;
  final List<TaskArtifact> artifacts;

  /// This run's calls and results, appended to the local process record.
  final String processLog;
}

/// Runs the persona-less errand agent once. It sees the task brief and its
/// own earlier process record, never the chat (ADR0088 §3).
class TaskAgentRunner {
  TaskAgentRunner({
    required this.loadSettings,
    required this.executor,
    ResolveBackgroundAgentRequestConfig? requestConfig,
    this.summarizerFactory,
    this.resultStore,
    this.keyFailureRecorder,
    this.resolveConversationId,
  }) : _requestConfig =
           requestConfig ?? BackgroundAgentService.resolveRequestConfig;

  final Future<String?> Function(String taskId)? resolveConversationId;
  final ProviderKeyFailureRecorder? keyFailureRecorder;
  final Future<AppSettings> Function() loadSettings;
  final TaskAgentExecutor executor;
  final ResolveBackgroundAgentRequestConfig _requestConfig;

  final Future<ContextSummarizerPort> Function()? summarizerFactory;
  final ToolResultStore? resultStore;

  static const askToolName = 'ask_user';
  static const materialToolName = 'submit_reference_material';

  Future<TaskRunOutcome> run({
    required String taskId,
    required String runId,
    String? conversationId,
    required String transcript,
    required TaskAgentCapabilities capabilities,
    required TaskAgentPreset preset,
    required KernelCancellation cancellation,
    bool readOnly = false,
    AgentToolPolicy? toolPolicy,
    List<Map<String, dynamic>>? contextMessages,

    /// Called before a tool with outside effects (HTTP, MCP) starts, so a
    /// later cancel can say the effect may already have happened.
    void Function()? onExternalStart,
    Future<void> Function()? onBeforeExternal,
    void Function(bool Function(String) steer)? onRunReady,
    Future<void> Function(ToolCall call, ToolResult result)? onToolStep,
    Future<void> Function(List<Map<String, dynamic>> messages)? onTranscript,
    void Function(String toolName, String progress)? onToolProgress,
  }) async {
    cancellation.throwIfCancelled();
    String? question;
    final askTool = AITool(
      name: askToolName,
      description: '任务说明不清楚、需要用户做决定时调用：向用户提一个问题，然后结束这一轮。',
      parameters: const {},
      inputSchema: const {
        'type': 'object',
        'properties': {
          'question': {'type': 'string', 'description': '一个具体的问题，最多 300 字'},
        },
        'required': ['question'],
      },
      effect: ToolEffect.readDiagnostic,
      terminationReason: KernelStopReason.waitingForUser,
      handler: (args) async {
        question = (args['question'] ?? '').toString().trim();
        return '问题已记下。';
      },
    );
    String? submittedMaterial;
    final materialTool = AITool(
      name: materialToolName,
      description: '提交供创作或分镜使用的完整参考素材原文。',
      parameters: const {},
      inputSchema: const {
        'type': 'object',
        'properties': {
          'content': {'type': 'string'},
        },
        'required': ['content'],
      },
      effect: ToolEffect.readDiagnostic,
      handler: (args) async {
        final content = (args['content'] as String).trim();
        submittedMaterial = submittedMaterial == null
            ? content
            : '$submittedMaterial\n\n$content';
        return '参考素材已附上。';
      },
    );
    final rawTools = [
      for (final tool in [
        for (final tool in capabilities.tools)
          if (preset.allowedPluginIds == null ||
              capabilities.toolOwners[tool.name] == null ||
              preset.allowedPluginIds!.contains(
                capabilities.toolOwners[tool.name],
              ))
            tool,
        ...?capabilities.workspaces?.tools(),
        askTool,
        materialTool,
        (resultStore ?? ToolResultStore.shared).reader(taskId),
      ])
        if (!readOnly || tool.effect != ToolEffect.write)
          _guarded(tool, cancellation, onExternalStart, onBeforeExternal),
    ];
    final tools = capabilities.workspaces?.enableScripts == true
        ? assembleCodemodeTools(rawTools)
        : rawTools;
    final settings = await loadSettings();
    final request = await _requestConfig(
      settings: settings,
      modelRef: preset.modelRef,
    );
    final workspacePrompt = await capabilities.workspaces?.prompt();
    final schemas = directToolSchemas(
      tools,
      activatedTools: calledMcpToolNames(contextMessages ?? const []),
    );
    final runtimeSchemas = List<Map<String, dynamic>>.of(schemas);
    var config = ApiConfig(
      toolResultStore: resultStore,
      toolResultOwner: taskId,
      currentWorkspaceId: () => capabilities.workspaces?.currentWorkspaceId,
      onRunReady: onRunReady,
      onToolStep: onToolStep,
      onTranscript: onTranscript,
      onToolProgress: onToolProgress,
      onToolSchemasChanged: (current) => runtimeSchemas
        ..clear()
        ..addAll(current),
      runtimeContext: RuntimeContextService(
        owner: taskId,
        resultStore: resultStore,
        policy: ContextWindowPolicy(
          configured: settings.contextWindowTokens,
          modelWindow: settings.getMaxContextTokens(request.modelFullId),
        ),
        tools: runtimeSchemas,
        summarizerFactory:
            summarizerFactory ??
            () async => BackgroundContextSummarizer(
              BackgroundAgentService(
                loadRecentMessages: (_, _) async => [],
                loadSettings: loadSettings,
                keyFailureRecorder: keyFailureRecorder,
              ),
              modelRef:
                  settings.resolveAvailableChatModelRef(
                    settings.compactionModel,
                  ) ??
                  request.modelFullId,
              contextTokens: settings.getMaxContextTokens(request.modelFullId),
            ),
      ),
      settings: settings,
      modelFullId: request.modelFullId,
      providerApiBase: request.providerApiBase,
      providerApiKey: request.providerApiKey,
      providerId: request.effectiveProviderId,
      providerApiKeyItemId: request.providerApiKeyItemId,
      providerApiKeyItemIndex: request.providerApiKeyItemIndex,
      providerApiKeyStrategy: request.providerApiKeyStrategy,
      cancellation: cancellation,
      customConfig: request.customConfig,
      messages: [
        {
          'role': 'system',
          'content': [
            _systemPrompt,
            if (readOnly) '当前任务为只读模式（read_only=true），只可查询和读取，严禁尝试写入或修改状态。',
            ?workspacePrompt,
            for (final entry in capabilities.prompts.entries)
              if (preset.allowedPluginIds == null ||
                  preset.allowedPluginIds!.contains(entry.key))
                entry.value,
          ].join('\n\n'),
        },
        ...?contextMessages,
        if (contextMessages == null) {'role': 'user', 'content': transcript},
      ],
      tools: schemas,
      modelTemperature: request.modelTemperature,
      modelTopP: request.modelTopP,
      modelContextMessageLimit: request.modelContextMessageLimit,
      toolPolicy:
          toolPolicy ??
          const AgentToolPolicy(authorization: AgentToolAuthorization.allowAll),
    );
    if (toolPolicy == null && capabilities.toolPolicyFactory != null) {
      config = config.copyWith(
        toolPolicy: await capabilities.toolPolicyFactory!(config),
      );
    }
    final result =
        await ModelRunScope(
          purpose: 'task_agent',
          conversationId:
              conversationId ?? await resolveConversationId?.call(taskId),
          turnId: runId,
        ).run(
          () => executeWithProviderKeyFailureRecording(
            config: config,
            recorder: keyFailureRecorder,
            cancellation: cancellation,
            execute: () => executor(
              config: config,
              tools: tools,
              sessionId: runId,
              cancellation: cancellation,
            ),
          ),
        );
    cancellation.throwIfCancelled();
    final reply =
        (result.processedText.trim().isNotEmpty
                ? result.processedText
                : result.replyText)
            .trim();
    return TaskRunOutcome(
      status: result.status,
      runningMessages: result.runningMessages,
      stopReason: result.stopReason,
      summary: reply,
      question: question?.isEmpty ?? true ? null : question,
      detail: submittedMaterial,
      artifacts: [
        for (final (workspace, path)
            in capabilities.workspaces?.changed ?? const <(String, String)>[])
          TaskArtifact(workspaceId: workspace, path: path),
      ],
      processLog: processLog(result.toolCalls, [
        for (final output in result.rawToolResults)
          ToolResult(
            toolCallId: output.toolCallId,
            name: output.name,
            result: await (resultStore ?? ToolResultStore.shared).preserve(
              taskId,
              output.persistentText,
              alreadyLimited:
                  tools
                      .where((tool) => tool.name == output.name)
                      .firstOrNull
                      ?.managesOutput ??
                  false,
            ),
            isError: output.isError,
          ),
      ], reply),
    );
  }

  /// Stops before any tool once the task is cancelled.
  static AITool _guarded(
    AITool tool,
    KernelCancellation cancellation,
    void Function()? onExternalStart,
    Future<void> Function()? onBeforeExternal,
  ) => AITool(
    name: tool.name,
    description: tool.description,
    parameters: tool.parameters,
    inputSchema: tool.inputSchema,
    validationSchema: tool.validationSchema,
    exposure: tool.exposure,
    outputSchema: tool.outputSchema,
    namespace: tool.namespace,
    effect: tool.effect,
    terminationReason: tool.terminationReason,
    executionTimeout: tool.executionTimeout,
    managesDeadline: tool.managesDeadline,
    managesOutput: tool.managesOutput,
    requiresHumanApproval: tool.requiresHumanApproval,
    richHandler: (args) async {
      cancellation.throwIfCancelled();
      if (tool.effect == ToolEffect.external) {
        await onBeforeExternal?.call();
        onExternalStart?.call();
      }
      cancellation.throwIfCancelled();
      return tool.invoke(args);
    },
    handler: (args) async {
      cancellation.throwIfCancelled();
      if (tool.effect == ToolEffect.external) {
        await onBeforeExternal?.call();
        onExternalStart?.call();
      }
      cancellation.throwIfCancelled();
      return tool.handler(args);
    },
  );

  /// Tool calls, preserved output references and the reply of one run.
  static String processLog(
    List<ToolCall> calls,
    List<ToolResult> results,
    String reply,
  ) {
    final byId = {for (final result in results) result.toolCallId: result};
    final lines = <String>[];
    for (final call in calls) {
      final result = byId[call.id]?.persistentText ?? '';
      lines.add(
        '- 调用 ${call.name} ${jsonEncode(call.arguments)}\n  结果：$result',
      );
    }
    if (reply.isNotEmpty) lines.add('- 你的回复：$reply');
    return lines.join('\n');
  }

  /// The brief for the first run.
  static String firstTranscript(String instruction) => '## 任务\n$instruction';

  /// The record carried into the run after the user answered.
  static String continueTranscript({
    required String previous,
    required String processLog,
    required String question,
    required String answer,
  }) =>
      '$previous\n\n## 之前的过程\n$processLog\n\n'
      '## 你提的问题\n$question\n\n## 用户的回答\n$answer';

  static const _systemPrompt =
      '你是 AIcove 的杂活助手，替一个角色在后台办事。你没有人设，不和用户聊天。\n'
      '只根据任务说明和可用工具完成任务，不编造结果；工具失败就如实说明。\n'
      '完成后用简短的中文写结果摘要（300 字以内）：做了什么、结果是什么、'
      '写了哪些文件。摘要会由角色转告用户。\n'
      '需要提取原文台词、外貌设定或大段参考资料供创作或分镜使用时，调用 submit_reference_material 提交完整素材原文，再写 300 字以内摘要；普通办事无需调用。\n'
      '任务说明不清楚或需要用户做决定时，调用 ask_user 提一个问题，然后结束。';
}
