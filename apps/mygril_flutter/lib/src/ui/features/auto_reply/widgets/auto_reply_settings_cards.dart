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
import '../../../../ui/shared/widgets/index.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../features/plugins/plugin_providers.dart';

/// 介绍说明卡片
class AutoReplyIntroCard extends StatelessWidget {
  const AutoReplyIntroCard({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return Card(
      color: colors.surfaceAlt,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: const Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('说明', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            SizedBox(height: 8),
            Text(
              '开启后，AI 会在聊天结束或特殊时间主动联系你。所有触发器都会遵守你设置的频率、冷却与免打扰策略，并可在下方查看或自定义。',
              style: TextStyle(fontSize: 13, height: 1.4),
            ),
          ],
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
    return Card(
      color: colors.panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.repeat, color: colors.primary),
                const SizedBox(width: 8),
                const Text('每日触发上限', style: TextStyle(fontWeight: FontWeight.w600)),
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
    return Card(
      color: colors.panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.timelapse, color: colors.primary),
                const SizedBox(width: 8),
                const Text('最短间隔', style: TextStyle(fontWeight: FontWeight.w600)),
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
    return Card(
      color: colors.panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              title: const Text('夜间免打扰'),
              subtitle: Text(
                draft.quietHoursEnabled
                    ? '${draft.quietHoursStart} - ${draft.quietHoursEnd}'
                    : '关闭后夜间也可能收到提醒',
                style: const TextStyle(fontSize: 12),
              ),
              value: draft.quietHoursEnabled,
              onChanged: onEnabledChanged,
              activeColor: colors.primary,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: draft.quietHoursEnabled ? () => onPickTime(true) : null,
                    child: Text('开始 ${draft.quietHoursStart}'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: draft.quietHoursEnabled ? () => onPickTime(false) : null,
                    child: Text('结束 ${draft.quietHoursEnd}'),
                  ),
                ),
              ],
            ),
          ],
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

    return Card(
      color: colors.panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
                  child: Text('AI 管家模型', style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                if (hasCustomModel)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: colors.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(4),
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
            InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  border: Border.all(color: colors.borderLight),
                  borderRadius: BorderRadius.circular(8),
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
          ],
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

    return Card(
      color: colors.panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
                  child: Text('AI 分析提示词', style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                if (!isDefault)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: colors.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(4),
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
    );
  }
}

/// 智能触发开关
class IntelligentTriggerSwitch extends ConsumerWidget {
  const IntelligentTriggerSwitch({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;
    final config = ref.watch(triggerPluginConfigProvider);
    
    return SwitchListTile(
      value: config.enabled,
      onChanged: (value) {
        ref.read(triggerPluginConfigProvider.notifier).setEnabled(value);
      },
      activeColor: colors.primary,
      title: const Text('允许 AI 设定提醒'),
      subtitle: Text(
        config.enabled ? 'AI 可通过对话（如"叫我起床"）自动设置系统闹钟' : 'AI 无法操作你的系统通知',
        style: const TextStyle(fontSize: 13),
      ),
      secondary: Icon(Icons.alarm_add, color: config.enabled ? colors.primary : colors.muted),
    );
  }
}
