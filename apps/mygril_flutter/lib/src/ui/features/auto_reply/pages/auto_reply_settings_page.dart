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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../ui/theme/tokens.dart';
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
  ConsumerState<AutoReplySettingsPage> createState() => _AutoReplySettingsPageState();
}

class _AutoReplySettingsPageState extends ConsumerState<AutoReplySettingsPage> {
  AutoReplySettings? _draft;
  bool _initialized = false;
  bool _saving = false;

  void _ensureDraft(AppSettings settings) {
    if (_initialized) return;
    _draft = settings.autoReplySettings;
    _initialized = true;
  }

  Future<void> _persist(AutoReplySettings next, {bool showToast = false}) async {
    setState(() {
      _draft = next;
      _saving = true;
    });
    try {
      await ref.read(appSettingsProvider.notifier).updateAutoReplySettings(next);
      if (mounted && showToast) {
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

  void _updateDraft(AutoReplySettings next, {bool saveImmediately = true, bool showToast = false}) {
    setState(() => _draft = next);
    if (saveImmediately) {
      _persist(next, showToast: showToast);
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
        backgroundColor: colors.surface,
        foregroundColor: colors.text,
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
              if (_saving) const LinearProgressIndicator(minHeight: 2) else const SizedBox(height: 2),
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
                      DailyLimitCard(
                        draft: draft,
                        onChanged: (value, {bool immediate = false}) {
                          final next = (_draft ?? draft).copyWith(dailyLimit: value);
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
                          final next = (_draft ?? draft).copyWith(minIntervalMinutes: value);
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
                        onEnabledChanged: (value) => _updateDraft(draft.copyWith(quietHoursEnabled: value)),
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
                            analyzerPrompt: AutoReplySettings.defaultAnalyzerPrompt,
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
    return SwitchListTile(
      value: draft.enabled,
      onChanged: (value) => _updateDraft(draft.copyWith(enabled: value)),
      activeColor: colors.primary,
      title: const Text('允许 AI 主动发消息'),
      subtitle: Text(
        draft.enabled ? 'AI 会根据对话氛围自动排程提醒' : '关闭后仅在你发起对话时才会回应',
        style: const TextStyle(fontSize: 13),
      ),
    );
  }

  Widget _buildDisabledHint(MoeColors colors) {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.borderLight),
      ),
      child: Text(
        '关闭后不会再收到主动消息。如果想体验"主动的小伴侣"，可以重新打开上方开关。',
        style: TextStyle(fontSize: 13, color: colors.textSecondary),
      ),
    );
  }

  Widget _buildExactAlarmSwitch(AutoReplySettings draft, MoeColors colors) {
    return SwitchListTile(
      value: draft.allowExactAlarm,
      onChanged: (value) => _updateDraft(draft.copyWith(allowExactAlarm: value)),
      title: const Text('尝试使用精准提醒'),
      subtitle: const Text('需要系统授权，能减小延迟但更耗电'),
      activeColor: colors.primary,
    );
  }

  Future<void> _pickTime(AutoReplySettings draft, bool isStart) async {
    final initial = _parseTime(isStart ? draft.quietHoursStart : draft.quietHoursEnd);
    final picked = await showTimePicker(
      context: context,
      initialTime: initial,
      helpText: isStart ? '免打扰开始时间' : '免打扰结束时间',
    );
    if (picked == null) return;
    final formatted = '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
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

  Future<void> _showModelPicker(AutoReplySettings draft, AppSettings settings) async {
    final result = await showAnalyzerModelPicker(
      context: context,
      draft: draft,
      settings: settings,
    );
    if (result == null) return;
    
    final next = result.model == null
        ? draft.copyWith(clearAnalyzerModel: true, clearAnalyzerProvider: true)
        : draft.copyWith(analyzerModel: result.model, analyzerProvider: result.provider);
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
    }
  }
}
