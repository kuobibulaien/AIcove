import '../../agent_plugins/aicove_plugin.dart';
import '../../agent_plugins/plugin_request_scope.dart';
import '../domain/handlers/ai_tool.dart';
import '../prompts/plugin_prompts.dart';
import 'web_search_plugin.dart';

/// Web search on the v2 registrar: the `web_search` / `web_fetch` tools and
/// taking over the model provider's built-in search.
AicovePlugin webSearchAgentPlugin(WebSearchPlugin registered) => AicovePlugin(
  id: registered.id,
  name: registered.name,
  capabilities: const {AppCapability.request},
  setup: (registrar) => registrar.add(
    AppContributions.requestScope,
    (inputs) =>
        WebSearchRequestScope(registered, pluginPrompts: inputs.pluginPrompts),
  ),
);

/// Reads the registered plugin, which already holds the saved
/// configuration and the request prompt snapshot.
class WebSearchRequestScope extends PluginRequestScope {
  WebSearchRequestScope(this.plugin, {this.pluginPrompts});

  final WebSearchPlugin plugin;
  final PluginPrompts? pluginPrompts;

  @override
  String get pluginId => plugin.id;

  @override
  String get pluginName => plugin.name;

  @override
  bool get active => plugin.enabled;

  @override
  List<AITool> tools() => plugin.getTools(prompts: pluginPrompts);

  @override
  bool get disablesBuiltinWebSearch => plugin.replacesModelBuiltinSearch;
}
