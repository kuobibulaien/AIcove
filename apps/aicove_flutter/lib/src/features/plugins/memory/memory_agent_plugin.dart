import '../../agent_plugins/aicove_plugin.dart';
import '../../agent_plugins/plugin_request_context.dart';
import '../../agent_plugins/plugin_request_scope.dart';
import 'memory_plugin.dart';

/// Long-term memory on the v2 registrar (ADR0035/0038): core memory goes
/// into the system prompt; memories retrieved for this turn's topic go into
/// the pre-request reminder, so the request prefix stays cacheable.
/// No tools, no reply processing.
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

  /// After time awareness (10) and image failure (20) reminders.
  static const archiveReminderOrder = 30;

  final MemoryPlugin plugin;

  /// Set by [prompt], which the send path builds before collecting
  /// reminders.
  String? _archive;

  @override
  String get pluginId => plugin.id;

  @override
  String get pluginName => plugin.name;

  @override
  bool get active => plugin.enabled;

  /// Fails closed without the request owner ([PluginRequestContext]).
  @override
  Future<String?> prompt(PluginRequestContext ctx) async {
    final memory = await plugin.buildMemory(
      userMessage: ctx.userMessage,
      conversationId: ctx.conversationId,
      resumeBackgroundWork: !ctx.readOnly,
    );
    _archive = memory?.archive;
    return memory?.core;
  }

  @override
  List<PluginReminder> reminders(DateTime requestTime) => switch (_archive) {
    final archive? => [PluginReminder(archiveReminderOrder, archive)],
    null => const [],
  };
}
