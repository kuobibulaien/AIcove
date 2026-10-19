import 'dart:convert';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show KernelCancellation, KernelCancelledException, ToolEffect;

import '../../../core/api/providers/provider_adapter.dart'
    show ToolCall, ToolResult;
import '../../../core/models/message_block.dart';
import '../../agent_plugins/tool_policy.dart';
import '../../agent_context/domain/agent_runtime_contracts.dart';
import '../../background_agent/background_agent_service.dart';
import '../../chat/services/chat_types.dart';
import '../../plugins/domain/handlers/ai_tool.dart';
import '../../settings/app_settings.dart';
import '../../workspace/application/workspace_toolset.dart';

/// What the errand agent may use in one run, already resolved by the single
/// rule role grant ∩ preset ∩ enabled ∩ present on this device (ADR0087 §1).
class TaskAgentCapabilities {
  const TaskAgentCapabilities({
    this.tools = const [],
    this.workspaces,
  });

  /// Office tools other than workspaces (web search, MCP).
  final List<AITool> tools;
  final WorkspaceToolset? workspaces;

  bool get isEmpty =>
      tools.isEmpty && (workspaces == null || workspaces!.workspaceIds.isEmpty);
}

/// The errand agent preset (ADR0088 §3). Presets only narrow: null lists
/// mean no further limit beyond the role's grants.
class TaskAgentPreset {
  const TaskAgentPreset({
    this.modelRef,
    this.maxRounds = 20,
    this.allowedPluginIds,
    this.allowedWorkspaceIds,
  });

  /// Null uses the default chat model.
  final String? modelRef;
  final int maxRounds;
  final Set<String>? allowedPluginIds;
  final Set<String>? allowedWorkspaceIds;
}

typedef TaskAgentExecutor =
    Future<ApiCallResult> Function({
      required ApiConfig config,
      required List<AITool> tools,
      required String sessionId,
      required int maxRounds,
      required KernelCancellation cancellation,
    });

/// Result of one run of the errand agent.
class TaskRunOutcome {
  const TaskRunOutcome({
    required this.summary,
    required this.question,
    required this.artifacts,
    required this.processLog,
  });

  final String summary;

  /// Set when the agent asked the user something; the task then waits.
  final String? question;
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
  }) : _requestConfig =
           requestConfig ?? BackgroundAgentService.resolveRequestConfig;

  final Future<AppSettings> Function() loadSettings;
  final TaskAgentExecutor executor;
  final ResolveBackgroundAgentRequestConfig _requestConfig;

  static const askToolName = 'ask_user';

  /// Per-result cut in the process record carried to the next run.
  static const transcriptResultChars = 2000;

  Future<TaskRunOutcome> run({
    required String taskId,
    required String runId,
    required String transcript,
    required TaskAgentCapabilities capabilities,
    required TaskAgentPreset preset,
    required KernelCancellation cancellation,
    AgentToolPolicy? toolPolicy,

    /// Called before a tool with outside effects (HTTP, MCP) starts, so a
    /// later cancel can say the effect may already have happened.
    void Function()? onExternalStart,
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
      handler: (args) async {
        question = (args['question'] ?? '').toString().trim();
        return '问题已记下。不要再调用工具，直接用一句话结束这一轮。';
      },
    );
    final tools = [
      for (final tool in [
        ...capabilities.tools,
        ...?capabilities.workspaces?.tools(),
        askTool,
      ])
        _guarded(tool, cancellation, onExternalStart),
    ];
    final settings = await loadSettings();
    final request = await _requestConfig(
      settings: settings,
      modelRef: preset.modelRef,
    );
    final workspacePrompt = await capabilities.workspaces?.prompt();
    final config = ApiConfig(
      settings: settings,
      modelFullId: request.modelFullId,
      providerApiBase: request.providerApiBase,
      providerApiKey: request.providerApiKey,
      customConfig: request.customConfig,
      messages: [
        {
          'role': 'system',
          'content': [_systemPrompt, ?workspacePrompt].join('\n\n'),
        },
        {'role': 'user', 'content': transcript},
      ],
      tools: [for (final tool in tools) tool.toOpenAISchema()],
      modelTemperature: request.modelTemperature,
      modelTopP: request.modelTopP,
      modelContextMessageLimit: request.modelContextMessageLimit,
      toolPolicy:
          toolPolicy ??
          const AgentToolPolicy(authorization: AgentToolAuthorization.allowAll),
    );
    final result = await executor(
      config: config,
      tools: tools,
      sessionId: runId,
      maxRounds: preset.maxRounds,
      cancellation: cancellation,
    );
    cancellation.throwIfCancelled();
    final reply = (result.processedText.trim().isNotEmpty
            ? result.processedText
            : result.replyText)
        .trim();
    return TaskRunOutcome(
      summary: reply,
      question: question?.isEmpty ?? true ? null : question,
      artifacts: [
        for (final (workspace, path)
            in capabilities.workspaces?.changed ?? const <(String, String)>[])
          TaskArtifact(workspaceId: workspace, path: path),
      ],
      processLog: processLog(result.toolCalls, result.rawToolResults, reply),
    );
  }

  /// Stops before any tool once the task is cancelled.
  static AITool _guarded(
    AITool tool,
    KernelCancellation cancellation,
    void Function()? onExternalStart,
  ) => AITool(
    name: tool.name,
    description: tool.description,
    parameters: tool.parameters,
    inputSchema: tool.inputSchema,
    effect: tool.effect,
    handler: (args) {
      if (cancellation.isCancelled) throw const KernelCancelledException();
      if (tool.effect == ToolEffect.external) onExternalStart?.call();
      return tool.handler(args);
    },
  );

  /// Tool calls, cut results and the reply of one run.
  static String processLog(
    List<ToolCall> calls,
    List<ToolResult> results,
    String reply,
  ) {
    final byId = {for (final result in results) result.toolCallId: result};
    final lines = <String>[];
    for (final call in calls) {
      final result = byId[call.id]?.result ?? '';
      final shown = result.length > transcriptResultChars
          ? '${result.substring(0, transcriptResultChars)}…'
          : result;
      lines.add('- 调用 ${call.name} ${jsonEncode(call.arguments)}\n  结果：$shown');
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
      '任务说明不清楚或需要用户做决定时，调用 ask_user 提一个问题，然后结束。';
}
