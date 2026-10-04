/// AutoReplySettingsPage - 主动关怀插件设置页
///
/// 重构记录：
/// - 2025-12-31: 拆分为多个组件文件，对话框改用底部弹窗 (MoeBottomSheet)
/// - 2026-09-15: 重写为 MoeSettingsGroup/MoeSettingsRow 分组式设置页
/// - 2026-10-03: 去掉全局总开关（由角色卡逐个勾选），首页只留常用项；
///   模型、提示词、准时提醒、后台运行与历史记录收进「更多设置」
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/shared/animations/parallax_slide_page_route.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../features/auto_reply/data/auto_reply_trigger.dart';
import '../../../../features/auto_reply/data/auto_reply_trigger_controller.dart';
import '../widgets/auto_reply_settings_cards.dart';
import 'auto_reply_advanced_settings_page.dart';
import 'auto_reply_trigger_list_page.dart';

class AutoReplySettingsPage extends ConsumerStatefulWidget {
  const AutoReplySettingsPage({super.key});

  @override
  ConsumerState<AutoReplySettingsPage> createState() =>
      _AutoReplySettingsPageState();
}

class _AutoReplySettingsPageState extends ConsumerState<AutoReplySettingsPage> {
  /// 滑块拖动中的临时值；松手后写回设置并清空。
  AutoReplySettings? _dragging;

  Future<void> _save(AutoReplySettings next) async {
    try {
      await ref
          .read(appSettingsProvider.notifier)
          .updateAutoReplySettings(next);
    } catch (e) {
      if (mounted) MoeToast.error(context, '保存失败: $e');
    } finally {
      if (mounted) setState(() => _dragging = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);

    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      appBar: const MoeAppBar(title: '主动关怀', showBackButton: true),
      backgroundColor: context.moeColors.surface,
      body: settingsAsync.when(
        loading: () => const Center(child: MoeLoadingIndicator()),
        error: (e, _) => Center(
          child: MoeEmptyState(
            icon: Icons.error_outline,
            title: '加载失败',
            description: '$e',
          ),
        ),
        data: (settings) =>
            _buildContent(_dragging ?? settings.autoReplySettings),
      ),
    );
  }

  Widget _buildContent(AutoReplySettings current) {
    final pendingCount =
        ref
            .watch(autoReplyTriggersProvider)
            .valueOrNull
            ?.where(
              (t) => t.isActive || t.status == AutoReplyTriggerStatus.paused,
            )
            .length ??
        0;

    return MoeSettingsContent(
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
                  label: '待发送的消息',
                  trailingType: MoeSettingsRowTrailing.text,
                  detailText: pendingCount > 0 ? '$pendingCount 条' : '无',
                  onTap: () => Navigator.of(context).push(
                    ParallaxSlidePageRoute(
                      page: const AutoReplyTriggerListPage(),
                    ),
                  ),
                ),
                MoeSettingsRow(
                  label: '让 AI 帮你记提醒',
                  subtitle: '聊天里说「明早叫我起床」，AI 会到点来找你',
                  trailingType: MoeSettingsRowTrailing.switchControl,
                  switchValue: current.allowAiSetReminders,
                  onSwitchChanged: (value) =>
                      _save(current.copyWith(allowAiSetReminders: value)),
                ),
              ],
            ),
            const AutoReplySectionFooter('在角色资料的插件里打开「主动关怀」，这个角色才会主动找你。'),
            const SizedBox(height: MoeSettingsLayout.sectionGap),

            MoeSettingsGroup(
              title: '打扰程度',
              children: [
                AutoReplySliderTile(
                  label: '每天最多',
                  valueText: '${current.dailyLimit} 次',
                  value: current.dailyLimit.toDouble(),
                  min: 1,
                  max: 6,
                  divisions: 5,
                  onChanged: (value) => setState(
                    () => _dragging = current.copyWith(
                      dailyLimit: value.round(),
                    ),
                  ),
                  onChangeEnd: (value) =>
                      _save(current.copyWith(dailyLimit: value.round())),
                ),
                AutoReplySliderTile(
                  label: '两条之间至少隔',
                  valueText: _formatInterval(current.minIntervalMinutes),
                  value: current.minIntervalMinutes.toDouble(),
                  min: 30,
                  max: 360,
                  divisions: 11,
                  onChanged: (value) => setState(
                    () => _dragging = current.copyWith(
                      minIntervalMinutes: value.round(),
                    ),
                  ),
                  onChangeEnd: (value) => _save(
                    current.copyWith(minIntervalMinutes: value.round()),
                  ),
                ),
                MoeSettingsRow(
                  label: '夜间免打扰',
                  trailingType: MoeSettingsRowTrailing.switchControl,
                  switchValue: current.quietHoursEnabled,
                  onSwitchChanged: (value) =>
                      _save(current.copyWith(quietHoursEnabled: value)),
                ),
                if (current.quietHoursEnabled) ...[
                  MoeSettingsRow(
                    label: '开始',
                    trailingType: MoeSettingsRowTrailing.text,
                    detailText: current.quietHoursStart,
                    onTap: () => _pickTime(current, true),
                  ),
                  MoeSettingsRow(
                    label: '结束',
                    trailingType: MoeSettingsRowTrailing.text,
                    detailText: current.quietHoursEnd,
                    onTap: () => _pickTime(current, false),
                  ),
                ],
              ],
            ),
            const SizedBox(height: MoeSettingsLayout.sectionGap),

            MoeSettingsGroup(
              children: [
                MoeSettingsRow(
                  label: '更多设置',
                  subtitle: '模型、提示词、后台运行、历史记录',
                  onTap: () => Navigator.of(context).push(
                    ParallaxSlidePageRoute(
                      page: const AutoReplyAdvancedSettingsPage(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: MoeSettingsLayout.sectionGap),
          ],
        ),
      ),
    );
  }

  String _formatInterval(int minutes) {
    if (minutes < 60) return '$minutes 分钟';
    if (minutes % 60 == 0) return '${minutes ~/ 60} 小时';
    return '${(minutes / 60).toStringAsFixed(1)} 小时';
  }

  Future<void> _pickTime(AutoReplySettings current, bool isStart) async {
    final initial = _parseTime(
      isStart ? current.quietHoursStart : current.quietHoursEnd,
    );
    final picked = await showTimePicker(
      context: context,
      initialTime: initial,
      helpText: isStart ? '免打扰开始时间' : '免打扰结束时间',
    );
    if (picked == null) return;
    final formatted =
        '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
    await _save(
      isStart
          ? current.copyWith(quietHoursStart: formatted)
          : current.copyWith(quietHoursEnd: formatted),
    );
  }

  TimeOfDay _parseTime(String value) {
    final parts = value.split(':');
    final hour = int.tryParse(parts.first) ?? 0;
    final minute = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    return TimeOfDay(hour: hour.clamp(0, 23), minute: minute.clamp(0, 59));
  }
}
