import 'package:flutter/material.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/tokens.dart';
import '../../../settings/app_settings.dart';
import '../../../plugins/plugin_providers.dart';
import '../../data/auto_reply_trigger.dart';
import '../../data/auto_reply_trigger_controller.dart';
import '../widgets/auto_reply_trigger_form.dart';
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('主动回复设置已更新'), duration: Duration(seconds: 1)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败: $e'), duration: const Duration(seconds: 2)),
        );
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_eventMessage(next))));
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
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
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
                    _buildIntroCard(context),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const AutoReplyTriggerListPage(),
                                fullscreenDialog: true,
                              ),
                            );
                          },
                          icon: const Icon(Icons.list_alt_outlined),
                          label: const Text('查看待触发提醒'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: colors.primary,
                            side: BorderSide(color: colors.primary),
                          ),
                        ),
                        FilledButton.icon(
                          onPressed: () => showCreateAutoReplyTriggerSheet(context, ref),
                          icon: const Icon(Icons.flash_on),
                          label: const Text('创建自定义触发'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _buildEnabledSwitch(context, draft),
                    // Intelligent Trigger Switch
                    _buildIntelligentTriggerSwitch(context, ref),
                    if (!draft.enabled) _buildDisabledHint(context),
                    if (draft.enabled) ...[
                      const SizedBox(height: 16),
                      _buildDailyLimitCard(context, draft),
                      const SizedBox(height: 16),
                      _buildIntervalCard(context, draft),
                      const SizedBox(height: 16),
                      _buildQuietHoursCard(context, draft),
                      const SizedBox(height: 16),
                      _buildExactAlarmSwitch(context, draft),
                      const SizedBox(height: 16),
                      _buildAnalyzerPromptCard(context, draft),
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

  Widget _buildIntroCard(BuildContext context) {
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

  Widget _buildEnabledSwitch(BuildContext context, AutoReplySettings draft) {
    final colors = context.moeColors;
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

  Widget _buildDisabledHint(BuildContext context) {
    final colors = context.moeColors;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.borderLight),
      ),
      child: const Text(
        '关闭后不会再收到主动消息。如果想体验“主动的小伴侣”，可以重新打开上方开关。',
        style: TextStyle(fontSize: 13),
      ),
    );
  }

  Widget _buildDailyLimitCard(BuildContext context, AutoReplySettings draft) {
    final colors = context.moeColors;
    return Card(
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
              onChanged: (value) {
                final next = (_draft ?? draft).copyWith(dailyLimit: value.round());
                setState(() => _draft = next);
              },
              onChangeEnd: (value) {
                final next = (_draft ?? draft).copyWith(dailyLimit: value.round());
                _persist(next);
              },
            ),
            const Text('建议 1~5 次，过多可能显得"黏人"。', style: TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _buildIntervalCard(BuildContext context, AutoReplySettings draft) {
    final colors = context.moeColors;
    final hours = (draft.minIntervalMinutes / 60).toStringAsFixed(1);
    return Card(
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
              onChanged: (value) {
                final next = (_draft ?? draft).copyWith(minIntervalMinutes: value.round());
                setState(() => _draft = next);
              },
              onChangeEnd: (value) {
                final next = (_draft ?? draft).copyWith(minIntervalMinutes: value.round());
                _persist(next);
              },
            ),
            const Text('限制两次主动消息之间的冷却时间。', style: TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _buildQuietHoursCard(BuildContext context, AutoReplySettings draft) {
    final colors = context.moeColors;
    return Card(
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
              onChanged: (value) => _updateDraft(draft.copyWith(quietHoursEnabled: value)),
              activeColor: colors.primary,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: draft.quietHoursEnabled ? () => _pickTime(draft, true) : null,
                    child: Text('开始 ${draft.quietHoursStart}'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: draft.quietHoursEnabled ? () => _pickTime(draft, false) : null,
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

  Widget _buildExactAlarmSwitch(BuildContext context, AutoReplySettings draft) {
    final colors = context.moeColors;
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

  Widget _buildIntelligentTriggerSwitch(BuildContext context, WidgetRef ref) {
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
      secondary: Icon(Icons.alarm_add, color: config.enabled ? colors.primary : Colors.grey),
    );
  }

  Widget _buildAnalyzerPromptCard(BuildContext context, AutoReplySettings draft) {
    final colors = context.moeColors;
    final isDefault = draft.analyzerPrompt == AutoReplySettings.defaultAnalyzerPrompt;
    
    return Card(
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
                  child: Text(
                    'AI 分析提示词',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                if (!isDefault)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: colors.primary.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '自定义',
                      style: TextStyle(fontSize: 11, color: colors.primary),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'AI 用这个提示词分析对话，判断是否需要创建触发器。你可以根据喜好自定义。',
              style: TextStyle(fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _showEditPromptDialog(context, draft),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('编辑提示词'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: colors.primary,
                      side: BorderSide(color: colors.primary),
                    ),
                  ),
                ),
                if (!isDefault) ...[
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: () {
                      final next = draft.copyWith(
                        analyzerPrompt: AutoReplySettings.defaultAnalyzerPrompt,
                      );
                      _updateDraft(next, showToast: true);
                    },
                    icon: const Icon(Icons.restore, size: 18),
                    label: const Text('恢复默认'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: colors.textSecondary,
                      side: BorderSide(color: colors.borderLight),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showEditPromptDialog(BuildContext context, AutoReplySettings draft) async {
    final controller = TextEditingController(text: draft.analyzerPrompt);
    final colors = context.moeColors;
    
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑 AI 分析提示词'),
        content: SizedBox(
          width: double.maxFinite,
          child: TextField(
            controller: controller,
            maxLines: 16,
            decoration: InputDecoration(
              hintText: '请输入提示词...',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    
    if (result != null && result.trim().isNotEmpty) {
      final next = draft.copyWith(analyzerPrompt: result.trim());
      _updateDraft(next, showToast: true);
    }
  }
}
