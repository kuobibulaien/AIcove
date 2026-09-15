/// AutoReplySettingsCards - 主动回复设置页的分区组件
///
/// 2026-09-15 重写：旧版一摞独立卡片改为分组式设置页用的小组件：
/// - AutoReplySectionFooter 分组下方的灰色说明文字
/// - AutoReplySliderTile 分组内的滑块设置行
/// - AutoReplyKeepAliveSection Android 后台保活检查清单
library;

import 'package:flutter/material.dart';

import '../../../../core/services/android_keep_alive_manager.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';

/// 分组下方的灰色小字说明
class AutoReplySectionFooter extends StatelessWidget {
  const AutoReplySectionFooter(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          height: 1.5,
          color: context.moeColors.muted,
        ),
      ),
    );
  }
}

/// 分组卡片内的滑块设置行
class AutoReplySliderTile extends StatelessWidget {
  const AutoReplySliderTile({
    super.key,
    required this.label,
    required this.valueText,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    required this.onChangeEnd,
    this.hint,
    this.showDivider = true,
  });

  final String label;
  final String valueText;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final String? hint;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: MoeFontWeights.emphasis,
                  ),
                ),
              ),
              Text(
                valueText,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: MoeFontWeights.emphasis,
                  color: colors.primary,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: MoeSlider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: valueText,
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ),
        if (hint != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                hint!,
                style: TextStyle(fontSize: 12, color: colors.muted),
              ),
            ),
          )
        else
          const SizedBox(height: 4),
        if (showDivider)
          Divider(
            height: 0.5,
            thickness: 0.5,
            indent: 12,
            color: colors.divider,
          ),
      ],
    );
  }
}

/// 状态文字 + 右箭头，用于可点击的检查项
class AutoReplyStatusTrailing extends StatelessWidget {
  const AutoReplyStatusTrailing({super.key, required this.text, this.ok});

  final String text;

  /// null 表示中性（不标绿/红）
  final bool? ok;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final color = ok == null
        ? colors.muted
        : ok!
        ? colors.toastSuccess
        : colors.toastError;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(text, style: TextStyle(fontSize: 14, color: color)),
        const SizedBox(width: 4),
        Icon(Icons.chevron_right, size: 20, color: colors.muted),
      ],
    );
  }
}

/// Android 后台保活检查清单分区
///
/// 仅在 Android 上展示；把守护服务和各项系统授权合并成一张可点击的检查表。
class AutoReplyKeepAliveSection extends StatelessWidget {
  const AutoReplyKeepAliveSection({
    super.key,
    required this.status,
    required this.loading,
    required this.onRefresh,
    required this.onNotificationTap,
    required this.onBatteryTap,
    required this.onAutoStartTap,
    required this.onBackgroundProtectionTap,
    required this.onExactAlarmTap,
  });

  final AndroidKeepAliveStatus? status;
  final bool loading;
  final VoidCallback onRefresh;
  final VoidCallback onNotificationTap;
  final VoidCallback onBatteryTap;
  final VoidCallback onAutoStartTap;
  final VoidCallback onBackgroundProtectionTap;
  final VoidCallback onExactAlarmTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final status = this.status;
    final startError = (status?.lastStartError ?? '').trim();

    if (status == null) {
      return MoeSettingsGroup(
        title: '后台运行',
        children: [
          MoeSettingsRow(
            label: '系统状态',
            subtitle: loading ? '正在读取…' : '暂时没有取到状态，点右侧刷新',
            trailingType: MoeSettingsRowTrailing.custom,
            trailing: _RefreshControl(loading: loading, onTap: onRefresh),
            onTap: loading ? null : onRefresh,
          ),
        ],
      );
    }

    final deviceLabel = status.deviceLabel;
    final notificationOk =
        status.notificationPermissionGranted &&
        status.notificationsEnabled &&
        status.guardNotificationChannelEnabled &&
        status.notificationVisibleInDrawer;
    final notificationLabel = !status.notificationPermissionGranted
        ? '未授权'
        : !status.notificationsEnabled
        ? '通知总开关已关'
        : !status.guardNotificationChannelEnabled
        ? '守护渠道已关'
        : !status.notificationVisibleInDrawer
        ? '可能被系统隐藏'
        : '正常';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        MoeSettingsGroup(
          title: '后台运行',
          children: [
            if (startError.isNotEmpty)
              Container(
                margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                padding: const EdgeInsets.all(12),
                decoration: MoeG2Decoration(
                  radius: 10,
                  color: colors.toastError.withValues(alpha: 0.08),
                  border: Border.all(
                    color: colors.toastError.withValues(alpha: 0.25),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 16,
                      color: colors.toastError,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '守护启动失败：$startError',
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.4,
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            MoeSettingsRow(
              label: '守护服务',
              subtitle: status.serviceRunning
                  ? (deviceLabel.isNotEmpty
                        ? '前台守护运行中 · $deviceLabel'
                        : '前台守护运行中')
                  : '未运行，点右侧刷新重试',
              trailingType: MoeSettingsRowTrailing.custom,
              trailing: loading
                  ? _RefreshControl(loading: true, onTap: onRefresh)
                  : AutoReplyStatusTrailing(
                      text: status.serviceRunning ? '运行中' : '未运行',
                      ok: status.serviceRunning,
                    ),
              onTap: loading ? null : onRefresh,
            ),
            MoeSettingsRow(
              label: '通知',
              subtitle: '前台守护需要在通知栏显示一条常驻通知',
              trailingType: MoeSettingsRowTrailing.custom,
              trailing: AutoReplyStatusTrailing(
                text: notificationLabel,
                ok: notificationOk,
              ),
              onTap: onNotificationTap,
            ),
            MoeSettingsRow(
              label: '电池优化',
              subtitle: '加入白名单后系统不容易杀掉后台任务',
              trailingType: MoeSettingsRowTrailing.custom,
              trailing: AutoReplyStatusTrailing(
                text: status.batteryOptimizationIgnored ? '已加入白名单' : '仍受限',
                ok: status.batteryOptimizationIgnored,
              ),
              onTap: onBatteryTap,
            ),
            MoeSettingsRow(
              label: '自启动',
              subtitle: '重启或清理后让应用自己恢复',
              trailingType: MoeSettingsRowTrailing.text,
              detailText: '去设置',
              onTap: onAutoStartTap,
            ),
            MoeSettingsRow(
              label: '后台保护',
              subtitle: '允许 AIcove 后台活动或无限制运行',
              trailingType: MoeSettingsRowTrailing.text,
              detailText: '去设置',
              onTap: onBackgroundProtectionTap,
            ),
            MoeSettingsRow(
              label: '精准提醒',
              subtitle: '到点提醒更准，需要系统单独授权',
              trailingType: MoeSettingsRowTrailing.custom,
              trailing: AutoReplyStatusTrailing(
                text: status.canScheduleExactAlarms ? '已授权' : '未授权',
                ok: status.canScheduleExactAlarms,
              ),
              onTap: onExactAlarmTap,
            ),
          ],
        ),
        AutoReplySectionFooter(
          status.isXiaomi
              ? '检测到小米设备：建议按「通知 → 电池 → 自启动 → 后台保护」的顺序全部放开。'
              : '上面各项全部放开后，主动回复在后台最稳定。',
        ),
      ],
    );
  }
}

class _RefreshControl extends StatelessWidget {
  const _RefreshControl({required this.loading, required this.onTap});

  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    if (loading) {
      return SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation(colors.primary),
        ),
      );
    }
    return Icon(Icons.refresh, size: 20, color: colors.muted);
  }
}
