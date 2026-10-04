/// AutoReplyAdvancedSettingsPage - 主动关怀「更多设置」
///
/// 不常改的选项：后台判断用的模型与提示词、准时提醒、Android 后台运行检查清单、
/// 历史记录。前台保活由「是否有角色启用主动关怀」自动决定，这里只做系统授权检查。
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
import '../widgets/auto_reply_settings_cards.dart';
import '../widgets/auto_reply_dialogs.dart';
import 'auto_reply_history_log_page.dart';

class AutoReplyAdvancedSettingsPage extends ConsumerStatefulWidget {
  const AutoReplyAdvancedSettingsPage({super.key});

  @override
  ConsumerState<AutoReplyAdvancedSettingsPage> createState() =>
      _AutoReplyAdvancedSettingsPageState();
}

class _AutoReplyAdvancedSettingsPageState
    extends ConsumerState<AutoReplyAdvancedSettingsPage>
    with WidgetsBindingObserver {
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

  Future<void> _save(AutoReplySettings next) async {
    try {
      await ref
          .read(appSettingsProvider.notifier)
          .updateAutoReplySettings(next);
    } catch (e) {
      if (mounted) MoeToast.error(context, '保存失败: $e');
    }
  }

  Future<void> _refreshKeepAliveStatus({bool silent = false}) async {
    if (!AndroidKeepAliveManager.isSupported) return;
    if (mounted) setState(() => _loadingKeepAliveStatus = true);
    try {
      final status = await AndroidKeepAliveManager.getStatus();
      if (!mounted) return;
      setState(() => _keepAliveStatus = status);
    } catch (e) {
      if (mounted && !silent) {
        MoeToast.error(context, '读取后台运行状态失败: $e');
      }
    } finally {
      if (mounted) setState(() => _loadingKeepAliveStatus = false);
    }
  }

  /// 打开系统设置页，并按结果提示下一步。
  Future<void> _openSystemPage(
    Future<bool> Function() open, {
    required String success,
    required String failure,
  }) async {
    final opened = await open();
    if (!mounted) return;
    if (opened) {
      MoeToast.info(context, success);
    } else {
      MoeToast.warning(context, failure);
    }
  }

  Future<void> _handleExactAlarmChanged(
    AutoReplySettings current,
    bool enabled,
  ) async {
    await _save(current.copyWith(allowExactAlarm: enabled));
    if (!enabled || !AndroidKeepAliveManager.isSupported) return;
    if (_keepAliveStatus?.canScheduleExactAlarms == false) {
      await _openExactAlarmSettings();
    }
  }

  Future<void> _openExactAlarmSettings() => _openSystemPage(
    AndroidKeepAliveManager.openExactAlarmSettings,
    success: '请在系统页面允许精准提醒，返回后状态会自动刷新。',
    failure: '未能直接打开精准提醒设置，请手动到系统设置里放行。',
  );

  /// 通知权限没给就先申请，给了再跳系统通知设置检查渠道。
  Future<void> _handleNotificationTap() async {
    if (_keepAliveStatus?.notificationPermissionGranted == false) {
      await Permission.notification.request();
      await _refreshKeepAliveStatus(silent: true);
      return;
    }
    await _openNotificationSettings();
  }

  Future<void> _openNotificationSettings() => _openSystemPage(
    AndroidKeepAliveManager.openNotificationSettings,
    success: '请确认应用通知总开关和“后台运行”渠道都处于开启状态。',
    failure: '未能直接打开通知设置，请手动到系统设置里查找。',
  );

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);

    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      appBar: const MoeAppBar(title: '更多设置', showBackButton: true),
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
        data: (settings) => _buildContent(settings),
      ),
    );
  }

  Widget _buildContent(AppSettings settings) {
    final current = settings.autoReplySettings;
    final customPrompt =
        current.analyzerPrompt != AutoReplySettings.defaultAnalyzerPrompt;

    return MoeSettingsContent(
      child: Builder(
        builder: (context) => ListView(
          padding: moeUnderBarPadding(
            context,
            MoeSettingsLayout.verticalListPadding,
          ),
          children: [
            MoeSettingsGroup(
              title: '判断时机',
              children: [
                MoeSettingsRow(
                  label: '使用的模型',
                  trailingType: MoeSettingsRowTrailing.text,
                  detailText: _analyzerModelLabel(current),
                  onTap: () => _showModelPicker(current, settings),
                ),
                MoeSettingsRow(
                  label: '判断提示词',
                  trailingType: MoeSettingsRowTrailing.text,
                  detailText: customPrompt ? '已自定义' : '默认',
                  onTap: () => _showEditPromptSheet(current),
                ),
                if (customPrompt)
                  MoeSettingsRow(
                    label: '恢复默认提示词',
                    labelColor: context.moeColors.primary,
                    trailingType: MoeSettingsRowTrailing.none,
                    onTap: () => _save(
                      current.copyWith(
                        analyzerPrompt: AutoReplySettings.defaultAnalyzerPrompt,
                      ),
                    ),
                  ),
              ],
            ),
            const AutoReplySectionFooter('AI 在后台看聊天记录，决定什么时候主动找你；可以换成便宜的小模型。'),
            const SizedBox(height: MoeSettingsLayout.sectionGap),

            MoeSettingsGroup(
              children: [
                MoeSettingsRow(
                  label: '更准时',
                  subtitle: _exactAlarmSubtitle(current),
                  trailingType: MoeSettingsRowTrailing.switchControl,
                  switchValue: current.allowExactAlarm,
                  onSwitchChanged: (value) =>
                      _handleExactAlarmChanged(current, value),
                ),
                MoeSettingsRow(
                  label: '历史记录',
                  onTap: () => Navigator.of(context).push(
                    ParallaxSlidePageRoute(
                      page: const AutoReplyHistoryLogPage(),
                    ),
                  ),
                ),
              ],
            ),

            if (AndroidKeepAliveManager.isSupported) ...[
              const SizedBox(height: MoeSettingsLayout.sectionGap),
              AutoReplyKeepAliveSection(
                status: _keepAliveStatus,
                loading: _loadingKeepAliveStatus,
                onRefresh: _refreshKeepAliveStatus,
                onNotificationTap: _handleNotificationTap,
                onBatteryTap: () => _openSystemPage(
                  AndroidKeepAliveManager.requestIgnoreBatteryOptimizations,
                  success: '请在系统页面把 AIcove 设为不受限制，返回后状态会自动刷新。',
                  failure: '未能直接打开白名单页面，请手动到系统电池设置里放行。',
                ),
                onAutoStartTap: () => _openSystemPage(
                  AndroidKeepAliveManager.openAutoStartSettings,
                  success: '请把 AIcove 加入自启动，返回后继续刷新状态即可。',
                  failure: '未能直接打开自启动设置，请手动在系统设置里查找。',
                ),
                onBackgroundProtectionTap: () => _openSystemPage(
                  AndroidKeepAliveManager.openBackgroundProtectionSettings,
                  success: '请把 AIcove 设为允许后台活动或无限制运行。',
                  failure: '未能直接打开后台保护设置，请手动在系统设置里查找。',
                ),
                onExactAlarmTap: _openExactAlarmSettings,
              ),
              const AutoReplySectionFooter('有角色开着主动关怀时，通知栏会常驻一条后台运行通知，防止被系统杀掉。'),
            ],
            const SizedBox(height: MoeSettingsLayout.sectionGap),
          ],
        ),
      ),
    );
  }

  String _exactAlarmSubtitle(AutoReplySettings current) {
    if (!AndroidKeepAliveManager.isSupported) {
      return '仅 Android 生效';
    }
    if (_keepAliveStatus?.canScheduleExactAlarms == true) {
      return '系统已允许，提醒会按时送达';
    }
    return current.allowExactAlarm ? '已开启，但系统还没允许' : '提醒更准时，稍微更耗电';
  }

  String _analyzerModelLabel(AutoReplySettings current) {
    final model = current.analyzerModel;
    if (model == null || model.isEmpty) return '跟随对话模型';
    final provider = current.analyzerProvider;
    return provider == null || provider.isEmpty ? model : '$model ($provider)';
  }

  Future<void> _showModelPicker(
    AutoReplySettings current,
    AppSettings settings,
  ) async {
    final result = await showAnalyzerModelPicker(
      context: context,
      draft: current,
      settings: settings,
    );
    if (result == null) return;
    await _save(
      result.model == null
          ? current.copyWith(
              clearAnalyzerModel: true,
              clearAnalyzerProvider: true,
            )
          : current.copyWith(
              analyzerModel: result.model,
              analyzerProvider: result.provider,
            ),
    );
  }

  Future<void> _showEditPromptSheet(AutoReplySettings current) async {
    await showMoeAutoSaveTextEditor(
      context: context,
      title: '编辑判断提示词',
      initialValue: current.analyzerPrompt,
      maxLines: 12,
      onSave: (text) async {
        if (text.trim().isEmpty) throw const FormatException('提示词不能为空');
        final latest =
            ref.read(appSettingsProvider).valueOrNull?.autoReplySettings ??
            current;
        await ref
            .read(appSettingsProvider.notifier)
            .updateAutoReplySettings(
              latest.copyWith(analyzerPrompt: text.trim()),
            );
      },
    );
  }
}
