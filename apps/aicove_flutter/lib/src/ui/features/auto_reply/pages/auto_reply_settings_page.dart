/// AutoReplySettingsPage - 主动回复设置页面
///
/// 管理 AI 主动回复的各项设置。
///
/// 重构记录：
/// - 2025-12-31: 拆分为多个组件文件，对话框改用底部弹窗 (MoeBottomSheet)
/// - 2026-09-15: 重写为 MoeSettingsGroup/MoeSettingsRow 分组式设置页；
///   历史日志移入独立页面，Android 保活合并为一张可点击检查清单
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../../core/services/android_keep_alive_manager.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/shared/animations/parallax_slide_page_route.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../features/auto_reply/data/auto_reply_trigger.dart';
import '../../../../features/auto_reply/data/auto_reply_trigger_controller.dart';
import '../../../../features/auto_reply/presentation/widgets/auto_reply_trigger_form.dart';
import '../widgets/auto_reply_settings_cards.dart';
import '../widgets/auto_reply_dialogs.dart';
import 'auto_reply_history_log_page.dart';
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

  Future<void> _persist(
    AutoReplySettings next, {
    bool showToast = false,
  }) async {
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
        MoeToast.warning(context, '设置已保存，但通知栏前台保活同步失败：$keepAliveError');
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

  void _updateDraft(
    AutoReplySettings next, {
    bool saveImmediately = true,
    bool showToast = false,
  }) {
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

  Future<bool> _ensureNotificationPermission() async {
    if (!AndroidKeepAliveManager.isSupported) return true;
    const permission = Permission.notification;
    var status = await permission.status;
    if (status.isGranted) return true;

    status = await permission.request();
    if (status.isGranted) return true;
    if (!mounted) return false;

    final detail = status.isPermanentlyDenied || status.isRestricted
        ? '通知权限仍未开启，守护通知可能只会出现在系统任务管理器里。'
        : '通知权限未开启，通知栏前台保活可能无法稳定显示。';
    MoeToast.warning(context, detail);
    return false;
  }

  Future<void> _handleEnabledChanged(
    AutoReplySettings draft,
    bool enabled,
  ) async {
    var notificationPermissionGranted = true;
    if (enabled) {
      notificationPermissionGranted = await _ensureNotificationPermission();
    }

    await _persist(
      draft.copyWith(enabled: enabled, guardModeEnabled: enabled),
      showToast: true,
    );

    if (!mounted || !enabled) return;

    final status = _keepAliveStatus;
    if (status != null) {
      final startError = status.lastStartError.trim();
      if (startError.isNotEmpty) {
        MoeToast.warning(context, '主动回复已开启，但前台守护启动失败：$startError');
        return;
      }

      if (!status.notificationVisibleInDrawer) {
        final reason = !status.notificationPermissionGranted
            ? '主动回复已开启，但通知权限没开；守护通知可能只会出现在系统任务管理器里。'
            : !status.notificationsEnabled
            ? '主动回复已开启，但系统把 AIcove 的通知总开关关掉了；守护通知不会出现在通知栏。'
            : !status.guardNotificationChannelEnabled
            ? '主动回复已开启，但“后台运行”通知渠道被关闭了；请到通知设置里重新打开。'
            : '主动回复已开启，但系统暂时还没把守护通知展示出来，您可以在「后台运行」里刷新状态再看一眼。';
        MoeToast.warning(context, reason);
        return;
      }
    } else if (!notificationPermissionGranted) {
      MoeToast.warning(context, '通知权限仍未开启，守护通知可能不会出现在通知栏。');
      return;
    }

    if (status != null && !status.batteryOptimizationIgnored) {
      MoeToast.info(context, '建议顺手把电池优化、自启动和后台保护也放开。');
    }
  }

  Future<void> _handleExactAlarmChanged(
    AutoReplySettings draft,
    bool enabled,
  ) async {
    await _persist(draft.copyWith(allowExactAlarm: enabled), showToast: true);

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

  Future<void> _handleNotificationTap() async {
    final status = _keepAliveStatus;
    if (status != null && !status.notificationPermissionGranted) {
      await _ensureNotificationPermission();
      await _refreshKeepAliveStatus(silent: true);
      return;
    }
    await _handleOpenNotificationSettings();
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

  Future<void> _handleOpenNotificationSettings() async {
    final opened = await AndroidKeepAliveManager.openNotificationSettings();
    if (!mounted) return;
    if (opened) {
      MoeToast.info(context, '请确认应用通知总开关和“后台运行”渠道都处于开启状态。');
    } else {
      MoeToast.warning(context, '未能直接打开通知设置，请手动到系统设置里查找。');
    }
  }

  Future<void> _handleOpenExactAlarmSettings() async {
    final opened = await AndroidKeepAliveManager.openExactAlarmSettings();
    if (!mounted) return;
    if (opened) {
      MoeToast.info(context, '请在系统页面允许精准提醒，返回后状态会自动刷新。');
    } else {
      MoeToast.warning(context, '未能直接打开精准提醒设置，请手动到系统设置里放行。');
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AutoReplyTriggerEvent?>(autoReplyTriggerEventProvider, (
      previous,
      next,
    ) {
      if (next == null || !mounted) return;
      MoeToast.info(context, _eventMessage(next));
      ref.read(autoReplyTriggerEventProvider.notifier).state = null;
    });

    final settingsAsync = ref.watch(appSettingsProvider);

    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      appBar: const MoeAppBar(title: '主动回复', showBackButton: true),
      body: settingsAsync.when(
        loading: () => const Center(child: MoeLoadingIndicator()),
        error: (e, _) => Center(
          child: MoeEmptyState(
            icon: Icons.error_outline,
            title: '加载失败',
            description: '$e',
          ),
        ),
        data: (settings) => _buildContent(settings),
      ),
    );
  }

  Widget _buildContent(AppSettings settings) {
    _ensureDraft(settings);
    final draft = _draft ?? settings.autoReplySettings;
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
      child: Column(
        children: [
          if (_saving)
            const LinearProgressIndicator(minHeight: 2)
          else
            const SizedBox(height: 2),
          Expanded(
            child: Builder(
              builder: (context) => ListView(
                padding: moeUnderBarPadding(
                  context,
                  MoeSettingsLayout.verticalListPadding,
                ),
                children: [
                  // ===== 总开关 =====
                  MoeSettingsGroup(
                    titleFirst: true,
                    children: [
                      MoeSettingsRow(
                        label: '主动回复',
                        subtitle: draft.enabled
                            ? '开启中，AI 会在合适的时机主动联系你'
                            : '关闭后，AI 只在你发消息时回应',
                        trailingType: MoeSettingsRowTrailing.switchControl,
                        switchValue: draft.enabled,
                        onSwitchChanged: (value) =>
                            _handleEnabledChanged(draft, value),
                      ),
                      MoeSettingsRow(
                        label: '允许 AI 设定提醒',
                        subtitle: !draft.enabled
                            ? '需先开启主动回复；开启后 AI 才能在聊天里管理提醒'
                            : draft.allowAiSetReminders
                            ? 'AI 可在聊天中创建、查询和删除提醒'
                            : 'AI 不会再替你设置或管理提醒',
                        trailingType: MoeSettingsRowTrailing.switchControl,
                        switchValue: draft.allowAiSetReminders,
                        onSwitchChanged: (value) => _updateDraft(
                          draft.copyWith(allowAiSetReminders: value),
                          showToast: true,
                        ),
                      ),
                    ],
                  ),
                  AutoReplySectionFooter(
                    draft.enabled
                        ? '后台 Agent 会分析对话状态，自动排程并发送主动消息${AndroidKeepAliveManager.isSupported ? '，同时启用通知栏前台保活' : ''}。'
                        : '关闭后后台 Agent 不再排程主动消息；已创建的触发器会保留但不会发送。',
                  ),
                  const SizedBox(height: MoeSettingsLayout.sectionGap),

                  // ===== 触发器 =====
                  MoeSettingsGroup(
                    title: '触发器',
                    children: [
                      MoeSettingsRow(
                        label: '待触发',
                        subtitle: '已排程、尚未发送的主动消息',
                        trailingType: MoeSettingsRowTrailing.text,
                        detailText: pendingCount > 0 ? '$pendingCount 条' : '无',
                        onTap: () => Navigator.of(context).push(
                          ParallaxSlidePageRoute(
                            page: const AutoReplyTriggerListPage(),
                          ),
                        ),
                      ),
                      MoeSettingsRow(
                        label: '新建触发',
                        subtitle: '手动创建一条到点发送的主动消息',
                        onTap: () =>
                            showCreateAutoReplyTriggerSheet(context, ref),
                      ),
                      MoeSettingsRow(
                        label: '历史记录',
                        subtitle: '后台 Agent 决策与触发发送日志',
                        onTap: () => Navigator.of(context).push(
                          ParallaxSlidePageRoute(
                            page: const AutoReplyHistoryLogPage(),
                          ),
                        ),
                      ),
                    ],
                  ),

                  if (draft.enabled) ...[
                    const SizedBox(height: MoeSettingsLayout.sectionGap),

                    // ===== 频率与免打扰 =====
                    MoeSettingsGroup(
                      title: '频率与免打扰',
                      children: [
                        AutoReplySliderTile(
                          label: '每日上限',
                          valueText: '${draft.dailyLimit} 次/天',
                          value: draft.dailyLimit.toDouble(),
                          min: 1,
                          max: 6,
                          divisions: 5,
                          hint: '超过后当天不再主动发消息，建议 1~5 次',
                          onChanged: (value) => setState(
                            () => _draft = (_draft ?? draft).copyWith(
                              dailyLimit: value.round(),
                            ),
                          ),
                          onChangeEnd: (value) => _persist(
                            (_draft ?? draft).copyWith(
                              dailyLimit: value.round(),
                            ),
                          ),
                        ),
                        AutoReplySliderTile(
                          label: '最短间隔',
                          valueText: _formatInterval(draft.minIntervalMinutes),
                          value: draft.minIntervalMinutes.toDouble(),
                          min: 30,
                          max: 360,
                          divisions: 11,
                          hint: '两条主动消息之间的冷却时间',
                          onChanged: (value) => setState(
                            () => _draft = (_draft ?? draft).copyWith(
                              minIntervalMinutes: value.round(),
                            ),
                          ),
                          onChangeEnd: (value) => _persist(
                            (_draft ?? draft).copyWith(
                              minIntervalMinutes: value.round(),
                            ),
                          ),
                        ),
                        MoeSettingsRow(
                          label: '夜间免打扰',
                          subtitle: draft.quietHoursEnabled
                              ? '${draft.quietHoursStart} ~ ${draft.quietHoursEnd} 不发送'
                              : '关闭后夜间也可能收到主动消息',
                          trailingType: MoeSettingsRowTrailing.switchControl,
                          switchValue: draft.quietHoursEnabled,
                          onSwitchChanged: (value) => _updateDraft(
                            draft.copyWith(quietHoursEnabled: value),
                          ),
                        ),
                        if (draft.quietHoursEnabled) ...[
                          MoeSettingsRow(
                            label: '开始时间',
                            trailingType: MoeSettingsRowTrailing.text,
                            detailText: draft.quietHoursStart,
                            onTap: () => _pickTime(draft, true),
                          ),
                          MoeSettingsRow(
                            label: '结束时间',
                            trailingType: MoeSettingsRowTrailing.text,
                            detailText: draft.quietHoursEnd,
                            onTap: () => _pickTime(draft, false),
                          ),
                        ],
                        MoeSettingsRow(
                          label: '更准时的提醒',
                          subtitle: _exactAlarmSubtitle(draft),
                          trailingType: MoeSettingsRowTrailing.switchControl,
                          switchValue: draft.allowExactAlarm,
                          onSwitchChanged: (value) =>
                              _handleExactAlarmChanged(draft, value),
                        ),
                      ],
                    ),
                    const SizedBox(height: MoeSettingsLayout.sectionGap),

                    // ===== 后台 Agent =====
                    MoeSettingsGroup(
                      title: '后台 Agent',
                      children: [
                        MoeSettingsRow(
                          label: '独立模型',
                          subtitle: '主动回复由独立后台 Agent 负责，可用便宜的小模型',
                          trailingType: MoeSettingsRowTrailing.text,
                          detailText: _analyzerModelLabel(draft),
                          onTap: () => _showModelPicker(draft, settings),
                        ),
                        MoeSettingsRow(
                          label: '分析提示词',
                          subtitle: '后台 Agent 判断何时主动发消息所用的提示词',
                          trailingType: MoeSettingsRowTrailing.text,
                          detailText:
                              draft.analyzerPrompt ==
                                  AutoReplySettings.defaultAnalyzerPrompt
                              ? '默认'
                              : '已自定义',
                          onTap: () => _showEditPromptSheet(draft),
                        ),
                        if (draft.analyzerPrompt !=
                            AutoReplySettings.defaultAnalyzerPrompt)
                          MoeSettingsRow(
                            label: '恢复默认提示词',
                            labelColor: context.moeColors.primary,
                            trailingType: MoeSettingsRowTrailing.none,
                            onTap: () => _updateDraft(
                              draft.copyWith(
                                analyzerPrompt:
                                    AutoReplySettings.defaultAnalyzerPrompt,
                              ),
                              showToast: true,
                            ),
                          ),
                      ],
                    ),

                    // ===== Android 后台运行 =====
                    if (AndroidKeepAliveManager.isSupported) ...[
                      const SizedBox(height: MoeSettingsLayout.sectionGap),
                      AutoReplyKeepAliveSection(
                        status: _keepAliveStatus,
                        loading: _loadingKeepAliveStatus,
                        onRefresh: _refreshKeepAliveStatus,
                        onNotificationTap: _handleNotificationTap,
                        onBatteryTap: _handleRequestBatteryWhitelist,
                        onAutoStartTap: _handleOpenAutoStartSettings,
                        onBackgroundProtectionTap:
                            _handleOpenBackgroundProtectionSettings,
                        onExactAlarmTap: _handleOpenExactAlarmSettings,
                      ),
                    ],
                  ],
                  const SizedBox(height: MoeSettingsLayout.sectionGap),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatInterval(int minutes) {
    if (minutes < 60) return '$minutes 分钟';
    if (minutes % 60 == 0) return '${minutes ~/ 60} 小时';
    return '${(minutes / 60).toStringAsFixed(1)} 小时';
  }

  String _exactAlarmSubtitle(AutoReplySettings draft) {
    if (!AndroidKeepAliveManager.isSupported) {
      return '仅 Android 生效，可减少高优先级提醒的延迟';
    }
    final status = _keepAliveStatus;
    if (status?.canScheduleExactAlarms == true) {
      return '系统已授权精准提醒，高优先级触发更准时';
    }
    return draft.allowExactAlarm
        ? '已开启，但系统还没授权，可在「后台运行」里放行'
        : '需要系统授权，能减少延迟但更耗电';
  }

  String _analyzerModelLabel(AutoReplySettings draft) {
    final model = draft.analyzerModel;
    if (model == null || model.isEmpty) return '跟随对话模型';
    final provider = draft.analyzerProvider;
    return provider == null || provider.isEmpty ? model : '$model ($provider)';
  }

  Future<void> _pickTime(AutoReplySettings draft, bool isStart) async {
    final initial = _parseTime(
      isStart ? draft.quietHoursStart : draft.quietHoursEnd,
    );
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
    AutoReplySettings draft,
    AppSettings settings,
  ) async {
    final result = await showAnalyzerModelPicker(
      context: context,
      draft: draft,
      settings: settings,
    );
    if (result == null) return;

    final next = result.model == null
        ? draft.copyWith(clearAnalyzerModel: true, clearAnalyzerProvider: true)
        : draft.copyWith(
            analyzerModel: result.model,
            analyzerProvider: result.provider,
          );
    _updateDraft(next, showToast: true);
  }

  Future<void> _showEditPromptSheet(AutoReplySettings draft) async {
    await showMoeAutoSaveTextEditor(
      context: context,
      title: '编辑 AI 分析提示词',
      initialValue: draft.analyzerPrompt,
      maxLines: 12,
      onSave: (text) async {
        if (text.trim().isEmpty) throw const FormatException('提示词不能为空');
        final next = (_draft ?? draft).copyWith(analyzerPrompt: text.trim());
        await ref
            .read(appSettingsProvider.notifier)
            .updateAutoReplySettings(next);
        if (mounted) setState(() => _draft = next);
      },
    );
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
