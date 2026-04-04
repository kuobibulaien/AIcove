/// AutoReplySettingsPage - 主动回复设置页面
///
/// 管理 AI 主动回复的各项设置。
///
/// 重构记录：
/// - 2025-12-31: 拆分为多个组件文件，主页面精简至约280行
///   - 提取 AutoReplyIntroCard 介绍卡片
///   - 提取 DailyLimitCard 每日限制卡片
///   - 提取 IntervalCard 间隔卡片
///   - 提取 QuietHoursCard 免打扰卡片
///   - 提取 AnalyzerModelCard 模型选择卡片
///   - 提取 AnalyzerPromptCard 提示词卡片
///   - 对话框改用底部弹窗 (MoeBottomSheet)
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../../core/services/android_keep_alive_manager.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/shared/animations/parallax_slide_page_route.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../features/chat/data/auto_reply_trigger.dart';
import '../../../../features/chat/data/auto_reply_trigger_controller.dart';
import '../../../../features/chat/presentation/widgets/auto_reply_trigger_form.dart';
import '../widgets/auto_reply_settings_cards.dart';
import '../widgets/auto_reply_dialogs.dart';
import 'auto_reply_trigger_list_page.dart';

class AutoReplySettingsPage extends ConsumerStatefulWidget {
  const AutoReplySettingsPage({super.key});

  @override
  ConsumerState<AutoReplySettingsPage> createState() =>
      _AutoReplySettingsPageState();
}

class _AutoReplySettingsPageState extends ConsumerState<AutoReplySettingsPage>
    with WidgetsBindingObserver {
  AutoReplySettings? _draft;
  bool _initialized = false;
  bool _saving = false;
  bool _loadingKeepAliveStatus = false;
  AndroidKeepAliveStatus? _keepAliveStatus;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refreshKeepAliveStatus(silent: true));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshKeepAliveStatus(silent: true));
    }
  }

  void _ensureDraft(AppSettings settings) {
    if (_initialized) return;
    _draft = settings.autoReplySettings;
    _initialized = true;
  }

  Future<void> _persist(AutoReplySettings next,
      {bool showToast = false}) async {
    setState(() {
      _draft = next;
      _saving = true;
    });
    try {
      await ref
          .read(appSettingsProvider.notifier)
          .updateAutoReplySettings(next);
      String? keepAliveError;
      try {
        await AndroidKeepAliveManager.syncWithAutoReplySettings(next);
        await _refreshKeepAliveStatus(silent: true);
      } catch (e) {
        keepAliveError = '$e';
      }
      if (!mounted) return;
      if (keepAliveError != null) {
        MoeToast.warning(context, '设置已保存，但守护模式同步失败：$keepAliveError');
      } else if (showToast) {
        MoeToast.success(context, '主动回复设置已更新');
      }
    } catch (e) {
      if (mounted) {
        MoeToast.error(context, '保存失败: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  void _updateDraft(AutoReplySettings next,
      {bool saveImmediately = true, bool showToast = false}) {
    setState(() => _draft = next);
    if (saveImmediately) {
      _persist(next, showToast: showToast);
    }
  }

  Future<void> _refreshKeepAliveStatus({bool silent = false}) async {
    if (!AndroidKeepAliveManager.isSupported) {
      if (!mounted) return;
      setState(() {
        _keepAliveStatus = null;
        _loadingKeepAliveStatus = false;
      });
      return;
    }

    if (mounted) {
      setState(() => _loadingKeepAliveStatus = true);
    }

    try {
      final status = await AndroidKeepAliveManager.getStatus();
      if (!mounted) return;
      setState(() => _keepAliveStatus = status);
    } catch (e) {
      if (mounted && !silent) {
        MoeToast.error(context, '读取守护状态失败: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _loadingKeepAliveStatus = false);
      }
    }
  }

  Future<void> _ensureNotificationPermission() async {
    if (!AndroidKeepAliveManager.isSupported) return;
    const permission = Permission.notification;
    var status = await permission.status;
    if (status.isGranted) return;

    status = await permission.request();
    if (!mounted || status.isGranted) return;

    MoeToast.info(context, '通知权限未开启，守护通知可能无法稳定显示。');
  }

  Future<void> _handleGuardModeChanged(
    AutoReplySettings draft,
    bool enabled,
  ) async {
    if (enabled) {
      await _ensureNotificationPermission();
    }

    await _persist(
      draft.copyWith(guardModeEnabled: enabled),
      showToast: true,
    );

    if (!mounted || !enabled) return;

    final status = _keepAliveStatus;
    if (status != null && !status.batteryOptimizationIgnored) {
      MoeToast.info(context, '建议顺手把电池优化、自启动和后台保护也放开。');
    }
  }

  Future<void> _handleExactAlarmChanged(
    AutoReplySettings draft,
    bool enabled,
  ) async {
    await _persist(
      draft.copyWith(allowExactAlarm: enabled),
      showToast: true,
    );

    if (!mounted || !enabled || !AndroidKeepAliveManager.isSupported) return;

    final status = _keepAliveStatus;
    if (status != null && !status.canScheduleExactAlarms) {
      final opened = await AndroidKeepAliveManager.openExactAlarmSettings();
      if (!mounted) return;
      if (opened) {
        MoeToast.info(context, '请在系统页面允许精准提醒，返回后状态会自动刷新。');
      } else {
        MoeToast.warning(context, '未能直接打开精准提醒设置，请手动到系统设置里放行。');
      }
    }
  }

  Future<void> _handleRequestBatteryWhitelist() async {
    final opened =
        await AndroidKeepAliveManager.requestIgnoreBatteryOptimizations();
    if (!mounted) return;
    if (opened) {
      MoeToast.info(context, '请在系统页面把 AIcove 设为不受限制，返回后状态会自动刷新。');
    } else {
      MoeToast.warning(context, '未能直接打开白名单页面，请手动到系统电池设置里放行。');
    }
  }

  Future<void> _handleOpenAutoStartSettings() async {
    final opened = await AndroidKeepAliveManager.openAutoStartSettings();
    if (!mounted) return;
    if (opened) {
      MoeToast.info(context, '请把 AIcove 加入自启动，返回后继续刷新状态即可。');
    } else {
      MoeToast.warning(context, '未能直接打开自启动设置，请手动在系统设置里查找。');
    }
  }

  Future<void> _handleOpenBackgroundProtectionSettings() async {
    final opened =
        await AndroidKeepAliveManager.openBackgroundProtectionSettings();
    if (!mounted) return;
    if (opened) {
      MoeToast.info(context, '请把 AIcove 设为允许后台活动或无限制运行。');
    } else {
      MoeToast.warning(context, '未能直接打开后台保护设置，请手动在系统设置里查找。');
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AutoReplyTriggerEvent?>(
      autoReplyTriggerEventProvider,
      (previous, next) {
        if (next == null || !mounted) return;
        MoeToast.info(context, _eventMessage(next));
        ref.read(autoReplyTriggerEventProvider.notifier).state = null;
      },
    );

    final settingsAsync = ref.watch(appSettingsProvider);
    final colors = context.moeColors;

    return Scaffold(
      appBar: AppBar(
        title: const Text('主动回复设置'),
        backgroundColor: colors.headerColor,
        foregroundColor: colors.headerContentColor,
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(borderWidth),
          child: Container(height: borderWidth, color: colors.borderLight),
        ),
      ),
      backgroundColor: colors.surface,
      body: settingsAsync.when(
        loading: () => const Center(child: MoeLoadingIndicator()),
        error: (e, _) => Center(
          child: MoeEmptyState(
            icon: Icons.error_outline,
            title: '加载失败',
            description: '$e',
          ),
        ),
        data: (settings) {
          _ensureDraft(settings);
          final draft = _draft ?? settings.autoReplySettings;
          return Column(
            children: [
              if (_saving)
                const LinearProgressIndicator(minHeight: 2)
              else
                const SizedBox(height: 2),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    const AutoReplyIntroCard(),
                    const SizedBox(height: 12),
                    _buildActionButtons(colors),
                    const SizedBox(height: 16),
                    _buildEnabledSwitch(draft, colors),
                    const IntelligentTriggerSwitch(),
                    if (!draft.enabled) _buildDisabledHint(colors),
                    if (draft.enabled) ...[
                      const SizedBox(height: 16),
                      _buildKeepAliveCard(draft, colors),
                      const SizedBox(height: 16),
                      DailyLimitCard(
                        draft: draft,
                        onChanged: (value, {bool immediate = false}) {
                          final next =
                              (_draft ?? draft).copyWith(dailyLimit: value);
                          if (immediate) {
                            _persist(next);
                          } else {
                            setState(() => _draft = next);
                          }
                        },
                      ),
                      const SizedBox(height: 16),
                      IntervalCard(
                        draft: draft,
                        onChanged: (value, {bool immediate = false}) {
                          final next = (_draft ?? draft)
                              .copyWith(minIntervalMinutes: value);
                          if (immediate) {
                            _persist(next);
                          } else {
                            setState(() => _draft = next);
                          }
                        },
                      ),
                      const SizedBox(height: 16),
                      QuietHoursCard(
                        draft: draft,
                        onEnabledChanged: (value) => _updateDraft(
                            draft.copyWith(quietHoursEnabled: value)),
                        onPickTime: (isStart) => _pickTime(draft, isStart),
                      ),
                      const SizedBox(height: 16),
                      _buildExactAlarmSwitch(draft, colors),
                      const SizedBox(height: 16),
                      AnalyzerModelCard(
                        draft: draft,
                        settings: settings,
                        onTap: () => _showModelPicker(draft, settings),
                      ),
                      const SizedBox(height: 16),
                      AnalyzerPromptCard(
                        draft: draft,
                        onEdit: () => _showEditPromptSheet(draft),
                        onReset: () {
                          final next = draft.copyWith(
                            analyzerPrompt:
                                AutoReplySettings.defaultAnalyzerPrompt,
                          );
                          _updateDraft(next, showToast: true);
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildKeepAliveCard(AutoReplySettings draft, MoeColors colors) {
    final status = _keepAliveStatus;
    final deviceLabel = status?.deviceLabel;
    final isXiaomi = status?.isXiaomi == true;
    final guardRunning = status?.serviceRunning == true;
    final notificationsReady = status?.notificationsEnabled == true;
    final batteryReady = status?.batteryOptimizationIgnored == true;
    final exactReady = status?.canScheduleExactAlarms == true;
    final keepAliveSubtitle = draft.guardModeEnabled
        ? (guardRunning ? '常驻通知已启动，系统回收后会尽量自恢复' : '守护偏好已保存，正在尝试拉起前台服务')
        : '开启后会显示常驻通知，并在开机后自动恢复守护';
    final tipText = isXiaomi
        ? '检测到小米设备，建议按“通知 -> 电池无限制 -> 自启动 -> 后台保护”的顺序全部放开。'
        : '建议至少放开通知、电池优化和后台保护，这样主动回复在后台会更稳。';

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
                  Icon(Icons.shield_moon_outlined, color: colors.primary),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '守护模式',
                      style: TextStyle(fontWeight: MoeFontWeights.emphasis),
                    ),
                  ),
                  if (_loadingKeepAliveStatus)
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(colors.primary),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                deviceLabel?.isNotEmpty == true
                    ? '当前设备：$deviceLabel'
                    : 'Android 上可用，适合国产机型后台保活。',
                style: TextStyle(fontSize: 13, color: colors.textSecondary),
              ),
              const SizedBox(height: 12),
              MoeSettingsRow(
                icon: Icons.notifications_active_outlined,
                label: '前台守护服务',
                subtitle: keepAliveSubtitle,
                trailingType: MoeSettingsRowTrailing.switchControl,
                switchValue: draft.guardModeEnabled,
                onSwitchChanged: (value) =>
                    _handleGuardModeChanged(draft, value),
                showDivider: false,
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildStatusPill(
                    colors: colors,
                    icon: Icons.shield_outlined,
                    label: guardRunning ? '守护服务已运行' : '守护服务待启动',
                    active: guardRunning,
                  ),
                  _buildStatusPill(
                    colors: colors,
                    icon: Icons.notifications_outlined,
                    label: notificationsReady ? '通知权限已开' : '通知权限未开',
                    active: notificationsReady,
                  ),
                  _buildStatusPill(
                    colors: colors,
                    icon: Icons.battery_saver_outlined,
                    label: batteryReady ? '电池已无限制' : '电池仍受限',
                    active: batteryReady,
                  ),
                  _buildStatusPill(
                    colors: colors,
                    icon: Icons.alarm_on_outlined,
                    label: exactReady ? '精准提醒已授权' : '精准提醒未授权',
                    active: exactReady,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: MoeG2Decoration(
                  radius: 10,
                  color: colors.surfaceAlt,
                  border: Border.all(color: colors.borderLight),
                ),
                child: Text(
                  tipText,
                  style: TextStyle(
                      fontSize: 13, height: 1.4, color: colors.textSecondary),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  MoePrimaryButton(
                    label: '电池白名单',
                    icon: Icons.battery_5_bar_outlined,
                    onPressed: _handleRequestBatteryWhitelist,
                  ),
                  MoeSecondaryButton(
                    label: '自启动设置',
                    icon: Icons.restart_alt_outlined,
                    onPressed: _handleOpenAutoStartSettings,
                  ),
                  MoeSecondaryButton(
                    label: '后台保护',
                    icon: Icons.security_outlined,
                    onPressed: _handleOpenBackgroundProtectionSettings,
                  ),
                  MoeSecondaryButton(
                    label: '刷新状态',
                    icon: Icons.refresh,
                    onPressed: _loadingKeepAliveStatus
                        ? null
                        : () => _refreshKeepAliveStatus(),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusPill({
    required MoeColors colors,
    required IconData icon,
    required String label,
    required bool active,
  }) {
    final activeColor = active ? colors.toastSuccess : colors.muted;
    final backgroundColor = active
        ? colors.toastSuccess.withValues(alpha: 0.12)
        : colors.surfaceAlt;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: MoeG2Decoration(
        radius: 10,
        color: backgroundColor,
        border: Border.all(
          color: active
              ? colors.toastSuccess.withValues(alpha: 0.25)
              : colors.borderLight,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: activeColor),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: MoeFontWeights.emphasis,
              color: active ? colors.text : colors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons(MoeColors colors) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        MoeSecondaryButton(
          label: '查看待触发提醒',
          icon: Icons.list_alt_outlined,
          onPressed: () {
            Navigator.of(context).push(
              ParallaxSlidePageRoute(page: const AutoReplyTriggerListPage()),
            );
          },
        ),
        MoePrimaryButton(
          label: '创建自定义触发',
          icon: Icons.flash_on,
          onPressed: () => showCreateAutoReplyTriggerSheet(context, ref),
        ),
      ],
    );
  }

  Widget _buildEnabledSwitch(AutoReplySettings draft, MoeColors colors) {
    return MoeSettingsRow(
      icon: Icons.chat_bubble_outline,
      label: '允许 AI 主动发消息',
      subtitle: draft.enabled ? 'AI 会根据对话氛围自动排程提醒' : '关闭后仅在你发起对话时才会回应',
      trailingType: MoeSettingsRowTrailing.switchControl,
      switchValue: draft.enabled,
      onSwitchChanged: (value) => _updateDraft(draft.copyWith(enabled: value)),
      showDivider: false,
    );
  }

  Widget _buildDisabledHint(MoeColors colors) {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: MoeG2Decoration(
        radius: 12,
        color: colors.surface,
        border: Border.all(color: colors.borderLight),
      ),
      child: Text(
        '关闭后不会再收到主动消息。如果想体验"主动的小伴侣"，可以重新打开上方开关。',
        style: TextStyle(fontSize: 13, color: colors.textSecondary),
      ),
    );
  }

  Widget _buildExactAlarmSwitch(AutoReplySettings draft, MoeColors colors) {
    final status = _keepAliveStatus;
    final subtitle = !AndroidKeepAliveManager.isSupported
        ? '仅 Android 生效，开启后可减少高优先级提醒延迟'
        : status?.canScheduleExactAlarms == true
            ? '系统已允许精准提醒，高优先级触发会更准时'
            : draft.allowExactAlarm
                ? '已开启，但系统还没授权，请到系统设置里放行'
                : '需要系统授权，能减小延迟但更耗电';

    return MoeSettingsRow(
      icon: Icons.access_time,
      label: '尝试使用精准提醒',
      subtitle: subtitle,
      trailingType: MoeSettingsRowTrailing.switchControl,
      switchValue: draft.allowExactAlarm,
      onSwitchChanged: (value) => _handleExactAlarmChanged(draft, value),
      showDivider: false,
    );
  }

  Future<void> _pickTime(AutoReplySettings draft, bool isStart) async {
    final initial =
        _parseTime(isStart ? draft.quietHoursStart : draft.quietHoursEnd);
    final picked = await showTimePicker(
      context: context,
      initialTime: initial,
      helpText: isStart ? '免打扰开始时间' : '免打扰结束时间',
    );
    if (picked == null) return;
    final formatted =
        '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
    final next = isStart
        ? draft.copyWith(quietHoursStart: formatted)
        : draft.copyWith(quietHoursEnd: formatted);
    _updateDraft(next);
  }

  TimeOfDay _parseTime(String value) {
    final parts = value.split(':');
    final hour = int.tryParse(parts.first) ?? 0;
    final minute = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    return TimeOfDay(hour: hour.clamp(0, 23), minute: minute.clamp(0, 59));
  }

  Future<void> _showModelPicker(
      AutoReplySettings draft, AppSettings settings) async {
    final result = await showAnalyzerModelPicker(
      context: context,
      draft: draft,
      settings: settings,
    );
    if (result == null) return;

    final next = result.model == null
        ? draft.copyWith(clearAnalyzerModel: true, clearAnalyzerProvider: true)
        : draft.copyWith(
            analyzerModel: result.model, analyzerProvider: result.provider);
    _updateDraft(next, showToast: true);
  }

  Future<void> _showEditPromptSheet(AutoReplySettings draft) async {
    final result = await showEditPromptSheet(
      context: context,
      currentPrompt: draft.analyzerPrompt,
    );
    if (result != null && result.trim().isNotEmpty) {
      final next = draft.copyWith(analyzerPrompt: result.trim());
      _updateDraft(next, showToast: true);
    }
  }

  String _eventMessage(AutoReplyTriggerEvent event) {
    switch (event.type) {
      case AutoReplyTriggerEventType.created:
        return '已创建触发器：${event.title}';
      case AutoReplyTriggerEventType.fired:
        return '已触发：${event.title}';
      case AutoReplyTriggerEventType.deleted:
        return '已删除：${event.title}';
      case AutoReplyTriggerEventType.paused:
        return '已暂停：${event.title}';
      case AutoReplyTriggerEventType.resumed:
        return '已恢复：${event.title}';
      case AutoReplyTriggerEventType.expired:
        final reason = event.reason;
        if (reason != null && reason.isNotEmpty) {
          return '已过期：${event.title}（$reason）';
        }
        return '已过期：${event.title}';
    }
  }
}
