import 'dart:convert';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';

import '../../agent_plugins/aicove_plugin.dart';
import '../../agent_plugins/plugin_request_context.dart';
import '../../agent_plugins/plugin_request_scope.dart';
import '../../content_tags/domain/content_tag_registry.dart';
import '../../content_tags/domain/content_tag_spec.dart';
import '../../plugins/domain/handlers/ai_tool.dart';
import '../domain/agent_task.dart';
import '../../../core/models/message_block.dart';

/// The task a `delegate_task` call started (or continued), read from the
/// tool block's stored result; null for any other tool or a failed call.
String? delegateTaskIdOf(ToolBlock block) {
  if (block.toolName != delegateTaskToolName) return null;
  final raw = block.result?['content'] ?? block.result;
  try {
    final decoded = raw is String ? jsonDecode(raw) : raw;
    final id = decoded is Map ? decoded['task_id'] : null;
    return id is String && id.isNotEmpty ? id : null;
  } on FormatException {
    return null;
  }
}

/// Compile switch for ADR0088: off keeps office tools on the chat model.
const delegateTaskEnabled = bool.fromEnvironment(
  'AICOVE_DELEGATE_TASK',
  defaultValue: true,
);

const delegateTaskPluginId = 'delegate_task';
const delegateTaskToolName = 'delegate_task';

/// The receipt's text label (ADR0088 §4) declared per ADR0044. The core
/// block writes it through `taskReceiptLabel`; a test keeps the two in step.
const taskReceiptEventLabel = ContentEventLabelSpec(
  name: '杂活回执',
  ownerId: delegateTaskPluginId,
);

const delegateTaskContentTags = StaticContentTagProvider(
  providerId: delegateTaskPluginId,
  tagSpecs: [],
  eventLabels: [taskReceiptEventLabel],
  toolNames: {delegateTaskToolName},
);

/// Office plugins: the chat model hands these to the errand agent instead of
/// calling them (ADR0088 §1).
bool isOfficePluginId(String id) => id == 'web_search' || id.startsWith('mcp:');

/// What `delegate_task` does on this device. Each call returns the JSON the
/// chat model sees.
abstract interface class DelegateTaskPort {
  /// Persists the task before returning; [callKey] is the chat side of the
  /// request key (conversation, run, round, tool call); the port adds the
  /// device.
  Future<Map<String, Object?>> start({
    required String conversationId,
    required String instruction,
    required String? callKey,
    bool readOnly = false,
  });

  Future<Map<String, Object?>> reply({
    required String conversationId,
    required String taskId,
    required String answer,
    required String? callKey,
  });

  Future<Map<String, Object?>> cancel({
    required String conversationId,
    required String taskId,
    required String? callKey,
  });
}

/// The chat model's only office tool (ADR0088 §1–2). Built in, so a role
/// cannot turn it off; it applies only when the model can call tools.
AicovePlugin delegateTaskAgentPlugin(
  DelegateTaskPort port, {
  List<AgentTask> activeTasks = const [],
}) => AicovePlugin(
  id: delegateTaskPluginId,
  name: '派活',
  exposure: PluginExposure.builtin,
  capabilities: const {AppCapability.request},
  setup: (registrar) => registrar.add(
    AppContributions.requestScope,
    (inputs) => DelegateTaskRequestScope(
      port,
      active: inputs.supportsToolCalling,
      activeTasks: activeTasks,
    ),
  ),
);

class DelegateTaskRequestScope extends PluginRequestScope {
  DelegateTaskRequestScope(
    this.port, {
    required this.active,
    this.activeTasks = const [],
  });

  final List<AgentTask> activeTasks;

  final DelegateTaskPort port;

  @override
  final bool active;

  @override
  String get pluginId => delegateTaskPluginId;

  @override
  String get pluginName => '派活';

  @override
  Future<String?> prompt(PluginRequestContext ctx) async =>
      active ? _prompt : null;

  @override
  List<AITool> tools() => active ? [delegateTaskTool(port)] : const [];

  @override
  List<PluginReminder> reminders(DateTime requestTime) {
    if (!active || activeTasks.isEmpty) return const [];
    return [
      PluginReminder(
        30,
        [
          '已有后台任务，避免重复新建；可直接用 delegate_task（action=reply）追加要求或回答，或用 action=cancel 取消：',
          for (final task in activeTasks)
            'task_id=${task.id} status=${task.status.dbName} instruction=${_compactInstruction(task.instruction)}${task.status == AgentTaskStatus.needsInput ? '（正在等用户回答）' : ''}',
        ].join('\n'),
      ),
    ];
  }

  static String _compactInstruction(String instruction) {
    final line = instruction.replaceAll(RegExp(r'\s+'), ' ').trim();
    final chars = line.runes.toList();
    return chars.length <= 80
        ? line
        : '${String.fromCharCodes(chars.take(79))}…';
  }

  static const _prompt =
      '## 派活\n'
      '主业是自然聊天，非必要绝不调用工具。日常闲聊、情绪倾诉、角色扮演、写故事、画分镜，以及聊天中顺嘴提到的现实话题（电影、天气、日常梗等，只要用户没让你查），一律直接用当前上下文接话，严禁自发派活搜索，严禁为回忆人设或前文派活。仅当用户明确要求联网查资料、调外部服务、读写文件、管理 AIcove 设置/渠道/预设/角色/插件，或直接提问客观事实且不查无法作答时，才调用 delegate_task(action=start)。纯查询、对比、读资料类任务设 read_only=true。\n'
      '任务说明须包含目标和必要细节，后台看不到当前聊天。start 会短暂等待；返回 done、failed 或 needs_input 时根据 summary、完整 detail 和 artifacts 回答或追问；返回 accepted 时只简短说明正在处理，不编造结果。'
      '用 action=reply 回答或追加要求，用 action=cancel 取消已有任务。';
}

/// Builds the tool; the conversation and request key come from the runner's
/// [ToolCallContext].
AITool delegateTaskTool(DelegateTaskPort port) => AITool(
  name: delegateTaskToolName,
  description:
      '主业是自然聊天，非必要绝不调用工具。日常闲聊、情绪倾诉、角色扮演、写故事、画分镜，以及聊天中顺嘴提到的现实话题（电影、天气、日常梗等，只要用户没让你查），一律直接用当前上下文接话，严禁自发派活搜索，严禁为回忆人设或前文派活。仅当用户明确要求联网查资料、调外部服务、读写文件、管理 AIcove 设置/渠道/预设/角色/插件，或直接提问客观事实且不查无法作答时，才调用 delegate_task(action=start)。纯查询、对比、读资料类任务设 read_only=true。'
      'start 派活；reply 回答或追加要求；cancel 取消。返回 done、failed 或 needs_input 时根据 summary、完整 detail 和 artifacts 回答或追问；返回 accepted 时只简短说明正在处理，不编造结果。',
  parameters: const {},
  inputSchema: const {
    'type': 'object',
    'properties': {
      'action': {
        'type': 'string',
        'enum': ['start', 'reply', 'cancel'],
      },
      'instruction': {
        'type': 'string',
        'description': 'start 时必填：完整的任务说明，后台看不到当前聊天；reply 时也可填追加要求',
      },
      'task_id': {'type': 'string', 'description': 'reply／cancel 时必填'},
      'read_only': {
        'type': 'boolean',
        'description':
            'start 时可选（默认 false）：仅查资料或只读检查时设为 true，后台将禁止修改任何设置、角色、预设或文件',
      },
      'answer': {'type': 'string', 'description': 'reply 时填用户的回答或对进行中任务的追加要求'},
    },
    'required': ['action'],
  },
  effect: ToolEffect.write,
  handler: (args) async {
    final context = ToolCallContext.current;
    final conversationId = context?.sessionId;
    if (conversationId == null) {
      return jsonEncode({'error': '只能在聊天里派活'});
    }
    final callKey = context!.turnId.isEmpty
        ? null
        : [
            conversationId,
            context.turnId,
            context.round,
            context.toolCallId,
          ].join('|');
    String text(String key) => (args[key] ?? '').toString().trim();
    final replyText = text('answer').isNotEmpty
        ? text('answer')
        : text('instruction');
    final Map<String, Object?> result = switch (text('action')) {
      'start' when text('instruction').isNotEmpty => await port.start(
        conversationId: conversationId,
        instruction: text('instruction'),
        callKey: callKey,
        readOnly: args['read_only'] == true,
      ),
      'reply' || 'steer' || 'follow_up'
          when text('task_id').isNotEmpty && replyText.isNotEmpty =>
        await port.reply(
          conversationId: conversationId,
          taskId: text('task_id'),
          answer: replyText,
          callKey: callKey,
        ),
      'cancel' when text('task_id').isNotEmpty => await port.cancel(
        conversationId: conversationId,
        taskId: text('task_id'),
        callKey: callKey,
      ),
      _ => {
        'error':
            '参数不完整：start 要 instruction，reply 要 task_id 和 answer，cancel 要 task_id',
      },
    };
    return jsonEncode(result);
  },
);
