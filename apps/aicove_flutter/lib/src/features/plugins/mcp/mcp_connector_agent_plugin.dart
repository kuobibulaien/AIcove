import '../../agent_plugins/aicove_plugin.dart';
import '../../agent_plugins/plugin_request_scope.dart';
import '../domain/handlers/ai_tool.dart';
import 'mcp_connector_plugin.dart';

/// An MCP connector on the v2 registrar: only its tools, and only for roles
/// that turn it on explicitly ("all plugins" does not include it).
AicovePlugin mcpConnectorAgentPlugin(McpConnectorPlugin registered) =>
    AicovePlugin(
      id: registered.id,
      name: registered.name,
      exposure: PluginExposure.roleExplicit,
      capabilities: const {AppCapability.request},
      setup: (registrar) => registrar.add(
        AppContributions.requestScope,
        (_) => McpConnectorRequestScope(registered),
      ),
    );

/// Reads the registered plugin, which holds the connector's saved tool list;
/// nothing here depends on the request.
class McpConnectorRequestScope extends PluginRequestScope {
  McpConnectorRequestScope(this.plugin);

  final McpConnectorPlugin plugin;

  @override
  String get pluginId => plugin.id;

  @override
  String get pluginName => plugin.name;

  @override
  bool get active => plugin.enabled;

  @override
  List<AITool> tools() => plugin.getTools();
}
