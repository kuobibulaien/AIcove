import '../../agent_plugins/aicove_plugin.dart';
import '../../agent_plugins/plugin_request_context.dart';
import '../../agent_plugins/plugin_request_scope.dart';
import '../prompts/plugin_prompts.dart';
import 'time_awareness_plugin.dart';

/// Time awareness on the v2 registrar: the tag semantics prompt and the
/// current-time reminder (ADR0063 order 10).
AicovePlugin timeAwarenessAgentPlugin(TimeAwarenessPlugin registered) =>
    AicovePlugin(
      id: registered.id,
      name: registered.name,
      capabilities: const {AppCapability.request},
      setup: (registrar) => registrar.add(
        AppContributions.requestScope,
        (inputs) => TimeAwarenessRequestScope(
          TimeAwarenessPlugin(
            registered.config.copyWith(
              currentTimePromptTemplate:
                  inputs.pluginPrompts.of(PluginPromptSlot.currentTime),
            ),
          ),
          inputs,
        ),
      ),
    );

/// One request's time awareness, on a configuration snapshot that carries
/// the request's current-time prompt template.
class TimeAwarenessRequestScope extends PluginRequestScope {
  TimeAwarenessRequestScope(this.snapshot, this.inputs);

  final TimeAwarenessPlugin snapshot;
  final PluginRequestInputs inputs;

  @override
  String get pluginId => snapshot.id;

  @override
  String get pluginName => snapshot.name;

  @override
  bool get active => snapshot.enabled;

  @override
  Future<String?> prompt(PluginRequestContext ctx) async =>
      snapshot.buildTagSemanticsPrompt();

  @override
  List<PluginReminder> reminders(DateTime requestTime) {
    if (!snapshot.enabled) return const [];
    final payload = snapshot.buildSystemReminderPayload(
      currentTime: requestTime,
      previousUserMessageTime: inputs.previousUserMessageTime,
    );
    if (payload == null) return const [];
    final content = inputs.reminders.buildReminderContent(payload);
    return content.isEmpty ? const [] : [PluginReminder(10, content)];
  }

  @override
  TimeContextTrace get timeContextTrace => TimeContextTrace(
        pluginName: snapshot.name,
        enabled: snapshot.enabled,
        config: snapshot.getConfig(),
      );
}
