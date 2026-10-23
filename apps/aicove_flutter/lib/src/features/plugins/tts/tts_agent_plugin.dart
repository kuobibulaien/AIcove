import '../../agent_plugins/aicove_plugin.dart';
import '../../agent_plugins/plugin_request_context.dart';
import '../../agent_plugins/plugin_request_scope.dart';
import '../../agent_plugins/plugin_response.dart';
import '../domain/plugin.dart';
import 'tts_plugin.dart';

/// Speech on the v2 registrar. The registered instance only signals that the
/// plugin is available; every request and reply uses the role's voice
/// request snapshot.
AicovePlugin ttsAgentPlugin(TtsPlugin registered) => AicovePlugin(
      id: registered.id,
      name: registered.name,
      capabilities: const {AppCapability.request, AppCapability.responses},
      setup: (registrar) {
        registrar.add(
          AppContributions.requestScope,
          (inputs) => TtsRequestScope(
            TtsPlugin.forRequest(
              inputs.voiceRequest,
              prompts: inputs.voicePrompts,
            ),
          ),
        );
        registrar.add(AppContributions.responseProcessor, (inputs) {
          final request = inputs.voiceRequest;
          if (request == null) {
            return ResponseFunction(
              registered.id,
              (text) async =>
                  PluginProcessResult(processedText: text, events: const []),
            );
          }
          final snapshot = TtsPlugin.forRequest(request);
          return ResponseFunction(
            registered.id,
            (text) async => snapshot.convertTtsTags(text),
            order: ResponseOrder.afterTagRemoval,
          );
        });
      },
    );

class TtsRequestScope extends PluginRequestScope {
  TtsRequestScope(this.snapshot);

  final TtsPlugin snapshot;

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
  Set<OutputTagHint> get outputTags =>
      active ? const {OutputTagHint.tts} : const {};
}
