/// AutoReplySettingsPage - 主动回复插件设置页
///
/// 重构记录：
/// - 2025-12-31: 拆分为多个组件文件，对话框改用底部弹窗 (MoeBottomSheet)
/// - 2026-09-15: 重写为 MoeSettingsGroup/MoeSettingsRow 分组式设置页
/// - 2026-10-03: 去掉全局总开关（由角色卡逐个勾选），首页只留常用项；
///   模型、提示词、准时提醒、后台运行与历史记录收进「更多设置」
/// - 2026-10-28: 改名回「主动回复」，「打扰程度」改为「回复频率」（默认 / 频繁），
///   支持角色独立设置（未单独设置时继承全局默认）
library;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/shared/animations/parallax_slide_page_route.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../features/auto_reply/data/auto_reply_trigger.dart';
import '../../../../features/auto_reply/data/auto_reply_trigger_controller.dart';
import '../../../../features/auto_reply/data/proactive_call.dart';
import '../widgets/auto_reply_settings_cards.dart';
import 'auto_reply_advanced_settings_page.dart';
import 'auto_reply_trigger_list_page.dart';

class AutoReplySettingsPage extends ConsumerStatefulWidget {
  final String? conversationId;
  final String? roleName;

  const AutoReplySettingsPage({
    super.key,
    this.conversationId,
    this.roleName,
  });

  @override
  ConsumerState<AutoReplySettingsPage> createState() =>
      _AutoReplySettingsPageState();
}

class _AutoReplySettingsPageState extends ConsumerState<AutoReplySettingsPage> {
  String? get _scopedConversationId {
    final id = widget.conversationId?.trim() ?? '';
    return id.isEmpty ? null : id;
  }

  bool get _isContactScoped => _scopedConversationId != null;

  Future<void> _save(AutoReplySettings next) async {
    try {
      await ref
          .read(appSettingsProvider.notifier)
          .updateAutoReplySettings(next);
    } catch (e) {
      if (mounted) MoeToast.error(context, '保存失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);

    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      appBar: const MoeAppBar(title: '主动回复', showBackButton: true),
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
        data: (settings) => _buildContent(settings.autoReplySettings),
      ),
    );
  }

  Widget _buildContent(AutoReplySettings rawSettings) {
    final scopeId = _scopedConversationId;
    final current = rawSettings.forContact(scopeId);
    final hasContactOverride = rawSettings.hasContactOverride(scopeId);
    final callsSupported = proactiveCallsSupported(defaultTargetPlatform);
    final pendingCount =
        ref
            .watch(autoReplyTriggersProvider)
            .valueOrNull
            ?.where(
              (t) =>
                  (t.isActive || t.status == AutoReplyTriggerStatus.paused) &&
                  (scopeId == null || t.conversationId == scopeId),
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
                      page: AutoReplyTriggerListPage(conversationId: scopeId),
                    ),
                  ),
                ),
                MoeSettingsRow(
                  label: '让 AI 帮你记提醒',
                  subtitle: '聊天里说「明早叫我起床」，AI 会到点来找你',
                  trailingType: MoeSettingsRowTrailing.switchControl,
                  switchValue: current.allowAiSetReminders,
                  onSwitchChanged: (value) => _save(
                    rawSettings.applyScoped(
                      scopeId,
                      allowAiSetReminders: value,
                    ),
                  ),
                ),
              ],
            ),
            AutoReplySectionFooter(
              _isContactScoped
                  ? '这里的设置只对当前角色生效。'
                  : '在角色资料的插件里打开「主动回复」，这个角色才会主动找你。这里设的是默认项，也可在角色资料里单独设置。',
            ),
            const SizedBox(height: MoeSettingsLayout.sectionGap),

            MoeSettingsGroup(
              children: [
                MoeSettingsRow(
                  key: const ValueKey('auto-reply-allow-calls'),
                  label: '允许主动打电话',
                  enabled: callsSupported,
                  trailingType: MoeSettingsRowTrailing.switchControl,
                  switchValue: callsSupported && current.allowProactiveCalls,
                  onSwitchChanged: callsSupported
                      ? (value) => _save(
                            rawSettings.applyScoped(
                              scopeId,
                              allowProactiveCalls: value,
                            ),
                          )
                      : null,
                ),
              ],
            ),
            AutoReplySectionFooter(
              callsSupported
                  ? '打开后，角色会按自己的性格决定要不要给你打电话，可能会比较频繁；免打扰时段不会响铃。'
                        '角色要开着语音、用 Fish Audio 音色，并配好语音识别才打得出来。'
                  : '这台设备暂不支持角色主动来电。',
            ),
            const SizedBox(height: MoeSettingsLayout.sectionGap),

            MoeSettingsGroup(
              children: [
                MoeSettingsRow(
                  key: const ValueKey('auto-reply-frequency'),
                  label: '回复频率',
                  trailingType: MoeSettingsRowTrailing.custom,
                  trailing: MoeSegmentedControl<AutoReplyFrequency>(
                    value: current.frequency,
                    onChanged: (value) => _save(
                      rawSettings.applyScoped(scopeId, frequency: value),
                    ),
                    height: 28,
                    expanded: false,
                    segments: const [
                      MoeSegment(
                        value: AutoReplyFrequency.normal,
                        label: '默认',
                      ),
                      MoeSegment(
                        value: AutoReplyFrequency.frequent,
                        label: '频繁',
                      ),
                    ],
                  ),
                ),
                MoeSettingsRow(
                  label: '夜间免打扰',
                  trailingType: MoeSettingsRowTrailing.switchControl,
                  switchValue: current.quietHoursEnabled,
                  onSwitchChanged: (value) => _save(
                    rawSettings.applyScoped(scopeId, quietHoursEnabled: value),
                  ),
                ),
                if (current.quietHoursEnabled) ...[
                  MoeSettingsRow(
                    label: '开始',
                    trailingType: MoeSettingsRowTrailing.text,
                    detailText: current.quietHoursStart,
                    onTap: () => _pickTime(rawSettings, current, true),
                  ),
                  MoeSettingsRow(
                    label: '结束',
                    trailingType: MoeSettingsRowTrailing.text,
                    detailText: current.quietHoursEnd,
                    onTap: () => _pickTime(rawSettings, current, false),
                  ),
                ],
              ],
            ),
            const AutoReplySectionFooter('选「频繁」时，角色会更常主动找你。'),
            const SizedBox(height: MoeSettingsLayout.sectionGap),

            MoeSettingsGroup(
              children: [
                if (_isContactScoped && hasContactOverride)
                  MoeSettingsRow(
                    key: const ValueKey('auto-reply-reset-contact'),
                    label: '恢复默认设置',
                    subtitle: '跟随全局主动回复设置',
                    trailingType: MoeSettingsRowTrailing.none,
                    onTap: () => _save(
                      rawSettings.clearContactOverride(scopeId!),
                    ),
                  ),
                MoeSettingsRow(
                  label: '更多设置',
                  subtitle: '模型、提示词、准时提醒、后台运行、历史记录',
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

  Future<void> _pickTime(
    AutoReplySettings rawSettings,
    AutoReplySettings current,
    bool isStart,
  ) async {
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
    final scopeId = _scopedConversationId;
    await _save(
      isStart
          ? rawSettings.applyScoped(scopeId, quietHoursStart: formatted)
          : rawSettings.applyScoped(scopeId, quietHoursEnd: formatted),
    );
  }

  TimeOfDay _parseTime(String value) {
    final parts = value.split(':');
    final hour = int.tryParse(parts.first) ?? 0;
    final minute = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    return TimeOfDay(hour: hour.clamp(0, 23), minute: minute.clamp(0, 59));
  }
}
