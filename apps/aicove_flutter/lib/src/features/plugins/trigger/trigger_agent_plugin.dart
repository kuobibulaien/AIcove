import '../../agent_plugins/aicove_plugin.dart';
import '../../agent_plugins/plugin_request_scope.dart';
import '../../agent_plugins/plugin_response.dart';
import '../domain/handlers/ai_tool.dart';
import '../prompts/plugin_prompts.dart';
import 'trigger_plugin.dart';

/// Proactive care triggers on the v2 registrar: the reminder tools, and
/// handling legacy trigger tags in replies.
AicovePlugin triggerAgentPlugin(TriggerPlugin registered) => AicovePlugin(
      id: registered.id,
      name: registered.name,
      capabilities: const {AppCapability.request, AppCapability.responses},
      setup: (registrar) {
        registrar.add(
          AppContributions.requestScope,
          (inputs) => TriggerRequestScope(
            registered,
            conversationId: inputs.conversationId ?? '',
            pluginPrompts: inputs.pluginPrompts,
            supportsToolCalling: inputs.supportsToolCalling,
          ),
        );
        registrar.add(
          AppContributions.responseProcessor,
          (_) => ResponseFunction(
            registered.id,
            registered.handleLegacyTriggerTags,
          ),
        );
      },
    );

class TriggerRequestScope extends PluginRequestScope {
  TriggerRequestScope(
    this.plugin, {
    String? conversationId,
    this.pluginPrompts,
    this.supportsToolCalling = true,
  })
      : conversationId = conversationId?.trim() ?? '';

  final TriggerPlugin plugin;
  final bool supportsToolCalling;
  final PluginPrompts? pluginPrompts;
  final String conversationId;

  @override
  String get pluginId => plugin.id;

  @override
  String get pluginName => plugin.name;

  @override
  bool get active => plugin.enabledForConversation(conversationId);

  @override
  List<AITool> tools() => !active || !supportsToolCalling
      ? const []
      : plugin.getTools(
        conversationId: conversationId,
        prompts: pluginPrompts,
      );
}
