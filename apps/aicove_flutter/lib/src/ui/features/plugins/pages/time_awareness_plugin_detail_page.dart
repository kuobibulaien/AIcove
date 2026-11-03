import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/plugins/prompts/plugin_prompts.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';
import 'plugin_prompts_page.dart';

class TimeAwarenessPluginDetailPage extends ConsumerWidget {
  const TimeAwarenessPluginDetailPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;
    final prompts = ref.watch(pluginPromptsProvider).valueOrNull;

    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: colors.surface,
      appBar: const MoeAppBar(title: '时间感知', showBackButton: true),
      body: MoeSettingsContent(
        child: Builder(
          builder: (context) => ListView(
            padding: moeUnderBarPadding(
              context,
              MoeSettingsLayout.verticalListPadding,
            ),
            children: [
              MoeSettingsGroup(
                title: '提示词（所有角色共用）',
                children: [
                  for (final slot in PluginPromptSlot.forPlugin(
                    'time_awareness',
                  ))
                    PluginPromptSlotRow(slot: slot, prompts: prompts),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
