import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';

import '../../agent_context/domain/preset_script_runtime.dart';
import '../../agent_context/domain/preset_tag_mapping.dart';
import '../../agent_context/domain/silly_tavern_preset.dart';
import '../../agent_context/infrastructure/quickjs_preset_runtime.dart';
import '../../agent_plugins/aicove_plugin.dart';
import '../../agent_plugins/plugin_request_scope.dart';
import '../../conversation_state/domain/mvu_content.dart';

/// Services the tavern compatibility plugin provides in the host scope.
abstract final class TavernCompatServices {
  /// Opens the preset script runtime the kernel stages use (preset prepare,
  /// reset and transport preview, response unpacking, preset tools).
  static const presetRuntime = ServiceKey<PresetRuntimeOpener>(
    'tavernCompat.presetRuntime',
  );
}

/// Tavern compatibility as a built-in plugin (batch 2 plan §3.5). It applies
/// when the request owner has a bound preset; binding resolution stays in
/// the preset port (ADR0042/0043) and only its result reaches the scope.
AicovePlugin tavernCompatAgentPlugin({
  PresetRuntimeOpener openPresetRuntime = QuickJsPresetRuntime.open,
}) =>
    AicovePlugin(
      id: tavernCompatPluginId,
      name: '酒馆兼容',
      exposure: PluginExposure.builtin,
      capabilities: const {KernelCapability.services, AppCapability.request},
      setup: (registrar) {
        registrar.service(TavernCompatServices.presetRuntime, openPresetRuntime);
        registrar.add(
          AppContributions.requestScope,
          (inputs) => TavernCompatRequestScope(inputs.boundPreset),
        );
      },
    );

const tavernCompatPluginId = 'tavern_compatibility';

class TavernCompatRequestScope extends PluginRequestScope {
  TavernCompatRequestScope(this.preset);

  final SillyTavernPreset? preset;

  @override
  String get pluginId => tavernCompatPluginId;

  @override
  String get pluginName => '酒馆兼容';

  @override
  bool get active => preset != null;

  @override
  List<String> get presetTagNames => preset == null
      ? const []
      : [for (final rule in inferPresetTagMapping(preset!).rules) rule.name];

  /// MVU update blocks in past replies are dropped from the request copy;
  /// state is injected by macro instead (ADR0071). Applied with or without a
  /// preset, as before.
  @override
  List<Map<String, dynamic>> filterRequestMessages(
    List<Map<String, dynamic>> messages,
  ) =>
      stripMvuUpdatesFromHistory(messages);
}
