import 'dart:convert';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';

import '../../agent_plugins/aicove_plugin.dart';
import '../../agent_plugins/plugin_request_context.dart';
import '../../agent_plugins/plugin_request_scope.dart';
import '../../content_tags/domain/content_tag_registry.dart';
import '../../content_tags/domain/content_tag_spec.dart';
import '../../plugins/domain/handlers/ai_tool.dart';

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

/// The chat model's only office tool (ADR0088 §1–2). Built in, so a role
/// cannot turn it off; it applies only when the model can call tools.
AicovePlugin delegateTaskAgentPlugin(DelegateTaskPort port) => AicovePlugin(
  id: delegateTaskPluginId,
  name: '派活',
  exposure: PluginExposure.builtin,
  capabilities: const {AppCapability.request},
  setup: (registrar) => registrar.add(
    AppContributions.requestScope,
    (inputs) => DelegateTaskRequestScope(port, active: inputs.supportsToolCalling),
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
  Future<String?> prompt(PluginRequestContext ctx) async => active ? _prompt : null;

  @override
  List<AITool> tools() => active ? [delegateTaskTool(port)] : const [];

  static const _prompt =
      '## 派活\n'
      '你自己不能上网、不能查资料、不能读写文件。需要查询、搜索、整理文件这类事时，'
      '调用 delegate_task（action=start）交给后台助手去办，然后用你自己的口吻简短回应，'
      '比如「我去查一下，好了告诉你」。\n'
      '收到「杂活回执」之前，只能说在处理，绝不能编造结果。回执里有问题时，'
      '用你的口吻转问用户；用户回答后用 action=reply 把回答交回去。'
      '用户说不用了，用 action=cancel 取消。';
}

/// Builds the tool; the conversation and request key come from the runner's
/// [ToolCallContext].
AITool delegateTaskTool(DelegateTaskPort port) => AITool(
  name: delegateTaskToolName,
  description:
      '把需要上网、查资料、读写文件的事交给后台助手。'
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
        : [conversationId, context.turnId, context.round, context.toolCallId]
              .join('|');
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
      _ => {'error': '参数不完整：start 要 instruction，reply 要 task_id 和 answer，cancel 要 task_id'},
    };
    return jsonEncode(result);
  },
);
