import 'dart:convert';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';

import '../../agent_plugins/aicove_plugin.dart';
import '../../agent_plugins/plugin_request_context.dart';
import '../../agent_plugins/plugin_request_scope.dart';
import '../../content_tags/domain/content_tag_registry.dart';
import '../../content_tags/domain/content_tag_spec.dart';
import '../../plugins/domain/handlers/ai_tool.dart';
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
const steerTaskToolName = 'steer_task';

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

/// Optional extension so existing delegation ports remain source-compatible.
abstract interface class TaskSteeringPort {
  Future<Map<String, Object?>> steer({
    required String conversationId,
    required String taskId,
    required String instruction,
  });
}

/// The chat model's only office tool (ADR0088 §1–2). Built in, so a role
/// cannot turn it off; it applies only when the model can call tools.
AicovePlugin delegateTaskAgentPlugin(DelegateTaskPort port) => AicovePlugin(
  id: delegateTaskPluginId,
  name: '派活',
  exposure: PluginExposure.builtin,
  capabilities: const {AppCapability.request},
  setup: (registrar) => registrar.add(
    AppContributions.requestScope,
    (inputs) =>
        DelegateTaskRequestScope(port, active: inputs.supportsToolCalling),
  ),
);

class DelegateTaskRequestScope extends PluginRequestScope {
  DelegateTaskRequestScope(this.port, {required this.active});

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
  List<AITool> tools() => active
      ? [
          delegateTaskTool(port),
          if (port is TaskSteeringPort) steerTaskTool(port as TaskSteeringPort),
        ]
      : const [];

  static const _prompt =
      '## 派活\n'
      '你工具列表里有的工具（比如表情包链接导入）直接用，不用派活。'
      '你没有上网搜索和读写文件的工具；这类事交给后台助手，调用 delegate_task（action=start）'
      '去办，然后用你自己的口吻简短回应，比如「我去查一下，好了告诉你」。\n'
      '收到「杂活回执」之前，只能说在处理，绝不能编造结果。回执里有问题时，'
      '用你的口吻转问用户；用户回答后用 action=reply 把回答交回去。'
      '用户说不用了，用 action=cancel 取消。';
}

/// Builds the tool; the conversation and request key come from the runner's
/// [ToolCallContext].
AITool delegateTaskTool(DelegateTaskPort port) => AITool(
  name: delegateTaskToolName,
  description:
      '把你没有工具、需要上网搜索或读写文件的事交给后台助手。'
      'start 派活（写清楚要做什么）；reply 回答助手的提问；cancel 取消任务。'
      '只返回受理结果，不等任务完成；结果之后以「杂活回执」送达。',
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
        'description': 'start 时必填：完整的任务说明，包含需要的全部细节',
      },
      'task_id': {'type': 'string', 'description': 'reply／cancel 时必填'},
      'answer': {'type': 'string', 'description': 'reply 时必填：用户的回答'},
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
    final Map<String, Object?> result = switch (text('action')) {
      'start' when text('instruction').isNotEmpty => await port.start(
        conversationId: conversationId,
        instruction: text('instruction'),
        callKey: callKey,
      ),
      'reply' when text('task_id').isNotEmpty && text('answer').isNotEmpty =>
        await port.reply(
          conversationId: conversationId,
          taskId: text('task_id'),
          answer: text('answer'),
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

AITool steerTaskTool(TaskSteeringPort port) => AITool(
  name: steerTaskToolName,
  description:
      '给已派出的任务追加要求或纠正方向，不新建任务。运行中会在下一模型轮接收；排队或等回答的任务下次执行时接收。不会代替回答提问，也不会重做已完成的操作。',
  parameters: const {},
  inputSchema: const {
    'type': 'object',
    'properties': {
      'task_id': {'type': 'string', 'minLength': 1},
      'instruction': {'type': 'string', 'minLength': 1},
    },
    'required': ['task_id', 'instruction'],
  },
  effect: ToolEffect.write,
  handler: (args) async {
    final conversation = ToolCallContext.current?.sessionId;
    if (conversation == null) return jsonEncode({'error': '只能在聊天里派活'});
    return jsonEncode(
      await port.steer(
        conversationId: conversation,
        taskId: args['task_id'] as String,
        instruction: args['instruction'] as String,
      ),
    );
  },
);
