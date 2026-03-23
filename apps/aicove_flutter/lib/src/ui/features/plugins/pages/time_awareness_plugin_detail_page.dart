import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/plugins/plugin_providers.dart';
import '../../../../features/plugins/time_awareness/time_awareness_config.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

class TimeAwarenessPluginDetailPage extends ConsumerWidget {
  const TimeAwarenessPluginDetailPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;
    final config = ref.watch(timeAwarenessPluginConfigProvider);
    final notifier = ref.read(timeAwarenessPluginConfigProvider.notifier);

    return Scaffold(
      backgroundColor: colors.surface,
      appBar: const MoeAppBar(
        title: '时间感知',
        showBackButton: true,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          _OverviewCard(config: config),
          const SizedBox(height: 16),
          MoeSettingsGroup(
            margin: EdgeInsets.zero,
            children: [
              MoeSettingsRow(
                icon: Icons.schedule_outlined,
                iconColor: colors.focus,
                label: '启用时间感知',
                subtitle: '默认开启。关闭后不再向 AI 注入当前时间和消息时序辅助信息。',
                trailingType: MoeSettingsRowTrailing.switchControl,
                switchValue: config.enabled,
                onSwitchChanged: notifier.setEnabled,
                showDivider: false,
              ),
            ],
          ),
          if (config.enabled) ...[
            const SizedBox(height: 16),
            MoeSettingsGroup(
              title: '注入内容',
              margin: EdgeInsets.zero,
              children: [
                MoeSettingsRow(
                  icon: Icons.history_outlined,
                  iconColor: colors.focus,
                  label: '历史消息时间戳',
                  subtitle: '为历史消息补上发送时间，帮助 AI 理解前后顺序和时间间隔。',
                  trailingType: MoeSettingsRowTrailing.switchControl,
                  switchValue: config.includeMessageTimestamp,
                  onSwitchChanged: notifier.setIncludeMessageTimestamp,
                ),
                MoeSettingsRow(
                  icon: Icons.access_time_outlined,
                  iconColor: colors.focus,
                  label: '当前时间注入',
                  subtitle: '把本次回复时的设备本地时间写入 <system-reminder>，让 AI 感知“现在”。',
                  trailingType: MoeSettingsRowTrailing.switchControl,
                  switchValue: config.includeCurrentTime,
                  onSwitchChanged: notifier.setIncludeCurrentTime,
                  showDivider: false,
                ),
              ],
            ),
            const SizedBox(height: 16),
            _TipsCard(config: config),
          ],
        ],
      ),
    );
  }
}

class _OverviewCard extends StatelessWidget {
  const _OverviewCard({required this.config});

  final TimeAwarenessConfig config;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: MoeG2Decoration(
        radius: MoeSmoothRadii.lg,
        color: colors.panel,
        border: Border.all(color: colors.borderLight, width: borderWidth),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: MoeG2Decoration(
                  radius: MoeSmoothRadii.md,
                  color: colors.focus.withOpacity(0.12),
                ),
                child: Icon(
                  Icons.schedule_outlined,
                  color: colors.focus,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '时间线辅助已接入聊天主链路',
                      style: TextStyle(
                        color: colors.text,
                        fontSize: 17,
                        fontWeight: MoeFontWeights.emphasis,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '它会把历史消息顺序和当前设备时间整理给 AI，避免“刚说完晚安又秒回早安”这类时间错位。',
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 13,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _StatusChip(
                label: config.enabled ? '插件已启用' : '插件已关闭',
                highlighted: config.enabled,
              ),
              _StatusChip(
                label: config.includeMessageTimestamp ? '历史消息带时间' : '历史消息不带时间',
                highlighted: config.enabled && config.includeMessageTimestamp,
              ),
              _StatusChip(
                label: config.includeCurrentTime ? '注入当前时间' : '不注入当前时间',
                highlighted: config.enabled && config.includeCurrentTime,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TipsCard extends StatelessWidget {
  const _TipsCard({required this.config});

  final TimeAwarenessConfig config;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final promptHint = config.currentTimePromptTemplate.trim().isEmpty
        ? '调试中心里未配置兼容提示词模板'
        : '兼容提示词模板仍保留在调试中心管理';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: MoeG2Decoration(
        radius: MoeSmoothRadii.lg,
        color: colors.componentBackground,
        border: Border.all(color: colors.borderLight, width: borderWidth),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, color: colors.primary, size: 18),
              const SizedBox(width: 8),
              Text(
                '生效说明',
                style: TextStyle(
                  color: colors.text,
                  fontSize: 14,
                  fontWeight: MoeFontWeights.emphasis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '1. 历史消息时间戳会直接影响聊天历史序列化。\n'
            '2. 当前时间注入会影响 system-reminder 内容。\n'
            '3. $promptHint。',
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.label,
    required this.highlighted,
  });

  final String label;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: MoeG2Decoration(
        radius: 999,
        color: highlighted
            ? colors.primary.withOpacity(0.12)
            : colors.surfaceAlt.withOpacity(0.8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: highlighted ? colors.primary : colors.textSecondary,
          fontSize: 12,
          fontWeight: MoeFontWeights.emphasis,
        ),
      ),
    );
  }
}
