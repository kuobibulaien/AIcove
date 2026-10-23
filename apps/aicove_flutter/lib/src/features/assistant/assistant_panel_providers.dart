import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'application/assistant_approvals.dart';
import 'application/assistant_panel_actions.dart';
import 'application/assistant_plugin.dart';
import 'application/assistant_settings_tools.dart';
import 'application/assistant_tool_group.dart';
import 'assistant_providers.dart';

/// Taps in AIcove酱's quick panels (ADR0094), rated and described like the
/// model's calls in the assistant chat.
final assistantPanelActionsProvider = Provider<AssistantPanelActions>((ref) {
  final toolset = ref.read(assistantToolsetProvider);
  final writes = ref.read(assistantWriteToolsProvider);
  final settings = ref.read(assistantSettingsToolsProvider);
  final cards = ref.read(assistantCardToolsProvider);
  final groups = ref.read(assistantToolGroupsProvider);
  return AssistantPanelActions(
    tools: () => [
      ...writes.tools(),
      ...settings.tools(),
      ...cards.tools(),
      for (final group in groups) ...group.tools(),
    ],
    riskOf: AssistantRequestScope.riskOf(
      toolset,
      writes,
      settings: settings,
      groups: groups,
    ),
    describe: (name, args) =>
        groups.ownerOf(name)?.describe(name, args) ??
        (AssistantSettingsTools.describes(name)
            ? settings.describe(name, args)
            : writes.describe(name, args)),
    alwaysAsk: () => ref.read(assistantAlwaysAskProvider).valueOrNull ?? false,
  );
});
