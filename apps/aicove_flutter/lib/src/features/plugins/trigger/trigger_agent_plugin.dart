import '../../agent_plugins/aicove_plugin.dart';
import '../../agent_plugins/plugin_request_scope.dart';
import '../../agent_plugins/plugin_response.dart';
import '../domain/handlers/ai_tool.dart';
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
          (_) => TriggerRequestScope(registered),
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
  TriggerRequestScope(this.plugin);

  final TriggerPlugin plugin;

  @override
  String get pluginId => plugin.id;

  @override
  String get pluginName => plugin.name;

  @override
  bool get active => plugin.enabled;

  @override
  List<AITool> tools() => plugin.getTools();
}
