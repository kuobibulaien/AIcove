import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/plugins/plugin_providers.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

class TimeAwarenessPluginDetailPage extends ConsumerWidget {
  const TimeAwarenessPluginDetailPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;
    final config = ref.watch(timeAwarenessPluginConfigProvider);
    final notifier = ref.read(timeAwarenessPluginConfigProvider.notifier);

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
                children: [
                  MoeSettingsRow(
                    label: '历史消息时间戳',
                    subtitle: '让 AI 知道每条消息的发送时间',
                    trailingType: MoeSettingsRowTrailing.switchControl,
                    switchValue: config.includeMessageTimestamp,
                    onSwitchChanged: notifier.setIncludeMessageTimestamp,
                  ),
                  MoeSettingsRow(
                    label: '当前时间注入',
                    subtitle: '让 AI 知道现在几点',
                    trailingType: MoeSettingsRowTrailing.switchControl,
                    switchValue: config.includeCurrentTime,
                    onSwitchChanged: notifier.setIncludeCurrentTime,
                    showDivider: false,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
