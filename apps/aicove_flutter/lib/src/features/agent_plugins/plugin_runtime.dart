import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';

import '../plugins/domain/handlers/ai_tool.dart';
import '../plugins/domain/plugin.dart';
import 'aicove_plugin.dart';
import 'plugin_request_scope.dart';
import 'plugin_response.dart';

/// App-scope plugin registry backed by the kernel [PluginHost]. Runs take a
/// [RunSnapshot]; enabling or disabling affects the next run only.
class PluginRuntime {
  PluginRuntime({KernelScope? scope}) : scope = scope ?? KernelScope() {
    _host = PluginHost(this.scope);
  }

  /// Mirrors the registered plugin list (registration order and enabled
  /// state); each plugin installs its own v2 description.
  factory PluginRuntime.fromPlugins(Iterable<Plugin> plugins) {
    final runtime = PluginRuntime();
    for (final plugin in plugins) {
      runtime.install(plugin.agentPlugin, enabled: plugin.enabled);
    }
    return runtime;
  }

  final KernelScope scope;
  late final PluginHost _host;
  final Map<String, AicovePlugin> _plugins = {};

  /// Installed plugins in installation order, which is also contribution
  /// order.
  List<AicovePlugin> get plugins => List.unmodifiable(_plugins.values);

  AicovePlugin? plugin(String id) => _plugins[id];

  bool isEnabled(String id) => _host.isEnabled(id);

  void install(AicovePlugin plugin, {bool enabled = true}) {
    _host.install(plugin.toKernel(), enabled: enabled);
    _plugins[plugin.id] = plugin;
  }

  void setEnabled(String id, bool enabled) =>
      enabled ? _host.enable(id) : _host.disable(id);

  RunSnapshot snapshot({String? agentId}) => _host.snapshot(agentId: agentId);

  /// Contributions under [key] from [pluginIds], ordered by installation
  /// order (not by enable order, which changes when a plugin is re-enabled),
  /// then by registration order within a plugin.
  List<Owned<T>> contributions<T>(
    RunSnapshot snapshot,
    ContributionKey<T> key, {
    required Set<String> pluginIds,
  }) {
    final order = {
      for (final (index, id) in _plugins.keys.indexed) id: index,
    };
    final entries = [
      for (final (index, entry) in snapshot.contributionsOf(key).indexed)
        if (pluginIds.contains(entry.owner)) (index, entry),
    ];
    entries.sort((a, b) {
      final byPlugin =
          (order[a.$2.owner] ?? 0).compareTo(order[b.$2.owner] ?? 0);
      return byPlugin != 0 ? byPlugin : a.$1.compareTo(b.$1);
    });
    return [for (final (_, entry) in entries) entry];
  }

  /// Plugins a role run includes, in installation order: enabled plugins
  /// filtered by [PluginExposure] and the role selection (null = "all
  /// plugins", which excludes explicit-only plugins). Built-in plugins are
  /// always included.
  List<String> selectForRole(Set<String>? enabledPluginIds) => [
        for (final plugin in _plugins.values)
          if (isEnabled(plugin.id) &&
              switch (plugin.exposure) {
                RoleDefaultExposure() =>
                  enabledPluginIds?.contains(plugin.id) ?? true,
                RoleExplicitExposure() =>
                  enabledPluginIds?.contains(plugin.id) ?? false,
                BuiltinExposure() => true,
                AgentOnlyExposure() => false,
              })
            plugin.id,
      ];

  /// Tools registered with the kernel `tool` contribution that [snapshot]
  /// shows its agent (take it with `snapshot(agentId: ...)`), as runner tools
  /// carrying their effect. Ordinary chat tools still come from request
  /// scopes; agent-only tools such as the guide agent's come from here.
  List<AITool> agentTools(RunSnapshot snapshot) => [
        for (final tool in snapshot.tools.values) aiToolOf(tool),
      ];

  static AITool aiToolOf(KernelTool tool) {
    final function = tool.schema['function'] is Map
        ? tool.schema['function'] as Map
        : tool.schema;
    final parameters = function['parameters'];
    return AITool(
      name: tool.name,
      description: (function['description'] ?? '').toString(),
      parameters: const {},
      inputSchema: parameters is Map
          ? Map<String, dynamic>.from(parameters)
          : const {'type': 'object', 'properties': <String, dynamic>{}},
      handler: tool.handler,
      effect: tool.effect,
    );
  }

  /// Builds the selected plugins' reply processors, in installation order;
  /// [runResponseProcessors] applies their [PluginResponseProcessor.order].
  List<PluginResponseProcessor> responseProcessors(
    RunSnapshot snapshot,
    List<String> pluginIds,
    PluginResponseInputs inputs,
  ) => [
        for (final entry in contributions(
          snapshot,
          AppContributions.responseProcessor,
          pluginIds: pluginIds.toSet(),
        ))
          entry.value(inputs),
      ];

  /// Builds every selected plugin's request scope, in installation order.
  List<PluginRequestScope> requestScopes(
    RunSnapshot snapshot,
    List<String> pluginIds,
    PluginRequestInputs inputs,
  ) => [
        for (final entry in contributions(
          snapshot,
          AppContributions.requestScope,
          pluginIds: pluginIds.toSet(),
        ))
          entry.value(inputs),
      ];
}
