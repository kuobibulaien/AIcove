import '../../agent_plugins/aicove_plugin.dart';
import '../../agent_plugins/plugin_request_context.dart';
import '../../agent_plugins/plugin_request_scope.dart';
import 'memory_plugin.dart';

/// Long-term memory on the v2 registrar: injects the request owner's memory
/// into the system prompt (ADR0035/0038). No tools, no reply processing.
AicovePlugin memoryAgentPlugin(MemoryPlugin registered) => AicovePlugin(
      id: registered.id,
      name: registered.name,
      capabilities: const {AppCapability.request},
      setup: (registrar) => registrar.add(
        AppContributions.requestScope,
        (_) => MemoryRequestScope(registered),
      ),
    );

class MemoryRequestScope extends PluginRequestScope {
  MemoryRequestScope(this.plugin);

  final MemoryPlugin plugin;

  @override
  String get pluginId => plugin.id;

  @override
  String get pluginName => plugin.name;

  @override
  bool get active => plugin.enabled;

  /// Fails closed without the request owner ([PluginRequestContext]).
  @override
  Future<String?> prompt(PluginRequestContext ctx) => plugin.buildMemoryPrompt(
        userMessage: ctx.userMessage,
        conversationId: ctx.conversationId,
      );
}
