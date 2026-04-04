/// AutoReplySettingsCards - 自动回复设置卡片组件
/// 
/// 从 auto_reply_settings_page.dart 提取，包含各种设置卡片。
/// 
/// 更新记录：
/// - 2025-12-31: 从 auto_reply_settings_page.dart 提取
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../features/plugins/plugin_providers.dart';

/// 介绍说明卡片
class AutoReplyIntroCard extends StatelessWidget {
  const AutoReplyIntroCard({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return MoeG2ClipRRect(
      radius: MoeSmoothRadii.sm,
      child: Material(
        color: colors.surfaceAlt,
        child: const Padding(
          padding: EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('说明', style: TextStyle(fontSize: 15, fontWeight: MoeFontWeights.emphasis)),
              SizedBox(height: 8),
              Text(
                '开启后，AI 会在聊天结束或特殊时间主动联系你。你还可以打开守护模式，提高小米等国产机型在后台运行时的稳定性。',
                style: TextStyle(fontSize: 13, height: 1.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 每日限制卡片
class DailyLimitCard extends StatelessWidget {
  final AutoReplySettings draft;
  final void Function(int value, {bool immediate}) onChanged;

  const DailyLimitCard({
    super.key,
    required this.draft,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return MoeG2ClipRRect(
      radius: MoeSmoothRadii.sm,
      child: Material(
        color: colors.panel,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.repeat, color: colors.primary),
                const SizedBox(width: 8),
                const Text('每日触发上限', style: TextStyle(fontWeight: MoeFontWeights.emphasis)),
                const Spacer(),
                Text('${draft.dailyLimit} 次/天', style: TextStyle(color: colors.primary)),
              ],
            ),
            Slider(
              value: draft.dailyLimit.toDouble(),
              min: 1,
              max: 6,
              divisions: 5,
              label: '${draft.dailyLimit} 次',
              activeColor: colors.primary,
              onChanged: (value) => onChanged(value.round(), immediate: false),
              onChangeEnd: (value) => onChanged(value.round(), immediate: true),
            ),
            Text('建议 1~5 次，过多可能显得"黏人"。',
                style: TextStyle(fontSize: 12, color: colors.muted)),
          ],
          ),
        ),
      ),
    );
  }
}

/// 最短间隔卡片
class IntervalCard extends StatelessWidget {
  final AutoReplySettings draft;
  final void Function(int value, {bool immediate}) onChanged;

  const IntervalCard({
    super.key,
    required this.draft,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final hours = (draft.minIntervalMinutes / 60).toStringAsFixed(1);
    return MoeG2ClipRRect(
      radius: MoeSmoothRadii.sm,
      child: Material(
        color: colors.panel,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.timelapse, color: colors.primary),
                const SizedBox(width: 8),
                const Text('最短间隔', style: TextStyle(fontWeight: MoeFontWeights.emphasis)),
                const Spacer(),
                Text('$hours 小时', style: TextStyle(color: colors.primary)),
              ],
            ),
            Slider(
              value: draft.minIntervalMinutes.toDouble(),
              min: 30,
              max: 360,
              divisions: 11,
              label: '$hours 小时',
              activeColor: colors.primary,
              onChanged: (value) => onChanged(value.round(), immediate: false),
              onChangeEnd: (value) => onChanged(value.round(), immediate: true),
            ),
            Text('限制两次主动消息之间的冷却时间。',
                style: TextStyle(fontSize: 12, color: colors.muted)),
          ],
          ),
        ),
      ),
    );
  }
}

/// 夜间免打扰卡片
class QuietHoursCard extends StatelessWidget {
  final AutoReplySettings draft;
  final ValueChanged<bool> onEnabledChanged;
  final void Function(bool isStart) onPickTime;

  const QuietHoursCard({
    super.key,
    required this.draft,
    required this.onEnabledChanged,
    required this.onPickTime,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return MoeG2ClipRRect(
      radius: MoeSmoothRadii.sm,
      child: Material(
        color: colors.panel,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MoeSettingsRow(
              icon: Icons.nightlight_round,
              label: '夜间免打扰',
              subtitle: draft.quietHoursEnabled
                  ? '${draft.quietHoursStart} - ${draft.quietHoursEnd}'
                  : '关闭后夜间也可能收到提醒',
              trailingType: MoeSettingsRowTrailing.switchControl,
              switchValue: draft.quietHoursEnabled,
              onSwitchChanged: onEnabledChanged,
              showDivider: false,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: MoeSecondaryButton(
                    label: '开始 ${draft.quietHoursStart}',
                    onPressed: draft.quietHoursEnabled ? () => onPickTime(true) : null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: MoeSecondaryButton(
                    label: '结束 ${draft.quietHoursEnd}',
                    onPressed: draft.quietHoursEnabled ? () => onPickTime(false) : null,
                  ),
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

/// AI 管家模型选择卡片
class AnalyzerModelCard extends StatelessWidget {
  final AutoReplySettings draft;
  final AppSettings settings;
  final VoidCallback onTap;

  const AnalyzerModelCard({
    super.key,
    required this.draft,
    required this.settings,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final hasCustomModel = draft.analyzerModel?.isNotEmpty == true;
    final currentDisplay = hasCustomModel
        ? '${draft.analyzerModel} (${draft.analyzerProvider ?? "auto"})'
        : '使用默认对话模型';

    return MoeG2ClipRRect(
      radius: MoeSmoothRadii.sm,
      child: Material(
        color: colors.panel,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.smart_toy_outlined, color: colors.primary),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('AI 管家模型', style: TextStyle(fontWeight: MoeFontWeights.emphasis)),
                ),
                if (hasCustomModel)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: MoeG2Decoration(
                      radius: 4,
                      color: colors.primary.withValues(alpha: 0.1),
                    ),
                    child: Text('独立', style: TextStyle(fontSize: 11, color: colors.primary)),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '触发器由独立的 AI 管家管理，不会污染聊天上下文。可以指定一个便宜的小模型来降低成本。',
              style: TextStyle(fontSize: 13, height: 1.4, color: colors.textSecondary),
            ),
            const SizedBox(height: 12),
            MoeG2ClipRRect(
              radius: 8,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onTap,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: MoeG2Decoration(
                      radius: 8,
                      border: Border.all(color: colors.borderLight),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          hasCustomModel ? Icons.check_circle : Icons.radio_button_unchecked,
                          size: 20,
                          color: hasCustomModel ? colors.primary : colors.muted,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(currentDisplay, style: TextStyle(fontSize: 14, color: colors.text)),
                        ),
                        Icon(Icons.chevron_right, color: colors.muted),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
          ),
        ),
      ),
    );
  }
}

/// AI 分析提示词卡片
class AnalyzerPromptCard extends StatelessWidget {
  final AutoReplySettings draft;
  final VoidCallback onEdit;
  final VoidCallback onReset;

  const AnalyzerPromptCard({
    super.key,
    required this.draft,
    required this.onEdit,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final isDefault = draft.analyzerPrompt == AutoReplySettings.defaultAnalyzerPrompt;

    return MoeG2ClipRRect(
      radius: MoeSmoothRadii.sm,
      child: Material(
        color: colors.panel,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.psychology_outlined, color: colors.primary),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('AI 分析提示词', style: TextStyle(fontWeight: MoeFontWeights.emphasis)),
                ),
                if (!isDefault)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: MoeG2Decoration(
                      radius: 4,
                      color: colors.primary.withValues(alpha: 0.1),
                    ),
                    child: Text('自定义', style: TextStyle(fontSize: 11, color: colors.primary)),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'AI 用这个提示词分析对话，判断是否需要创建触发器。你可以根据喜好自定义。',
              style: TextStyle(fontSize: 13, height: 1.4, color: colors.textSecondary),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: MoeSecondaryButton(
                    label: '编辑提示词',
                    icon: Icons.edit_outlined,
                    onPressed: onEdit,
                  ),
                ),
                if (!isDefault) ...[
                  const SizedBox(width: 12),
                  MoeSecondaryButton(
                    label: '恢复默认',
                    icon: Icons.restore,
                    onPressed: onReset,
                  ),
                ],
              ],
            ),
          ],
          ),
        ),
      ),
    );
  }
}

/// 智能触发开关
class IntelligentTriggerSwitch extends ConsumerWidget {
  const IntelligentTriggerSwitch({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(triggerPluginConfigProvider);

    return MoeSettingsRow(
      icon: Icons.alarm_add,
      label: '允许 AI 设定提醒',
      subtitle: config.enabled ? 'AI 可通过对话（如"叫我起床"）自动设置系统闹钟' : 'AI 无法操作你的系统通知',
      trailingType: MoeSettingsRowTrailing.switchControl,
      switchValue: config.enabled,
      onSwitchChanged: (value) {
        ref.read(triggerPluginConfigProvider.notifier).setEnabled(value);
      },
      showDivider: false,
    );
  }
}
