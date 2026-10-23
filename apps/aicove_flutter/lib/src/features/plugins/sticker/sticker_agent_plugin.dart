import '../../agent_plugins/aicove_plugin.dart';
import '../../agent_plugins/plugin_request_context.dart';
import '../../agent_plugins/plugin_request_scope.dart';
import '../../agent_plugins/plugin_response.dart';
import '../prompts/plugin_prompts.dart';
import 'sticker_plugin.dart';

/// Stickers on the v2 registrar: the tag list prompt (per-request template
/// snapshot) and turning `<sticker/>` tags in replies into sticker events,
/// both limited to the packs the role may use.
AicovePlugin stickerAgentPlugin(StickerPlugin registered) => AicovePlugin(
      id: registered.id,
      name: registered.name,
      capabilities: const {AppCapability.request, AppCapability.responses},
      setup: (registrar) {
        registrar.add(
          AppContributions.requestScope,
          (inputs) => StickerRequestScope(
            StickerPlugin(
              registered.config.copyWith(
                systemPromptTemplate:
                    inputs.pluginPrompts.of(PluginPromptSlot.sticker),
              ),
            ),
            rolePluginIds: inputs.rolePluginIds,
          ),
        );
        registrar.add(
          AppContributions.responseProcessor,
          (inputs) => ResponseFunction(
            registered.id,
            (text) => registered.convertStickerTags(
              text,
              rolePluginIds: inputs.rolePluginIds,
            ),
          ),
        );
      },
    );

class StickerRequestScope extends PluginRequestScope {
  StickerRequestScope(this.snapshot, {this.rolePluginIds});

  final StickerPlugin snapshot;

  /// The role's plugin list carrying its pack grants (null = all packs).
  final Set<String>? rolePluginIds;

  @override
  String get pluginId => snapshot.id;

  @override
  String get pluginName => snapshot.name;

  @override
  bool get active => snapshot.enabled;

  @override
  Future<String?> prompt(PluginRequestContext ctx) async =>
      snapshot.buildSystemPrompt(rolePluginIds: rolePluginIds);
}
