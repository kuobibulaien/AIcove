import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:figma_squircle/figma_squircle.dart';

import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../data/auto_reply_trigger.dart';
import '../../data/auto_reply_trigger_controller.dart';
import '../../providers2.dart';

Future<void> showCreateAutoReplyTriggerSheet(
  BuildContext context,
  WidgetRef ref,
) {
  final colors = context.moeColors;
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (context) {
      const sheetBorderRadius = SmoothBorderRadius.vertical(
        top: SmoothRadius(cornerRadius: 24, cornerSmoothing: 0.6),
      );
      final viewInsets = MediaQuery.viewInsetsOf(context);
      final screenHeight = MediaQuery.sizeOf(context).height;

      return MoeG2ClipRRect.borderRadius(
        borderRadius: sheetBorderRadius,
        child: Container(
          constraints: BoxConstraints(maxHeight: screenHeight * 0.85),
          color: colors.surface,
          child: AnimatedPadding(
            duration: kAnimFast,
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.only(bottom: viewInsets.bottom),
            child: const SingleChildScrollView(child: _CreateTriggerSheet()),
          ),
        ),
      );
    },
  );
}

class _CreateTriggerSheet extends ConsumerStatefulWidget {
  const _CreateTriggerSheet();

  @override
  ConsumerState<_CreateTriggerSheet> createState() =>
      _CreateTriggerSheetState();
}

class _CreateTriggerSheetState extends ConsumerState<_CreateTriggerSheet> {
  final _titleCtrl = TextEditingController(text: '测试触发');
  final _promptCtrl = TextEditingController();
  AutoReplyTriggerType _type = AutoReplyTriggerType.delay;
  double _delayMinutes = 30;
  DateTime? _selectedDate;
  TimeOfDay? _selectedTime;
  bool _allowNight = false;
  bool _requireExact = false;
  bool _submitting = false;
  String? _error;
  String? _selectedContactId;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _promptCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final conversationsAsync = ref.watch(conversationsProvider);
    final colors = context.moeColors;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(bottom: 12),
            decoration: MoeG2Decoration(
              radius: 2,
              color: colors.borderLight,
            ),
          ),
          Text(
            '创建自定义触发',
            style: TextStyle(
                fontSize: 16, fontWeight: MoeFontWeights.emphasis, color: colors.text),
          ),
          const SizedBox(height: 16),
          MoeTextField(
            controller: _titleCtrl,
            label: '标题',
            hint: '例如：晚安提醒',
          ),
          const SizedBox(height: 12),
          conversationsAsync.when(
            data: (conversations) {
              return DropdownButtonFormField<String>(
                initialValue: _selectedContactId,
                decoration: InputDecoration(
                  labelText: '指定联系人 (可选)',
                  hintText: '默认使用当前活跃对话',
                  labelStyle: TextStyle(color: colors.textSecondary),
                  hintStyle: TextStyle(color: colors.muted),
                ),
                items: [
                  const DropdownMenuItem(
                    value: null,
                    child: Text('不指定 (当前活跃)'),
                  ),
                  ...conversations.map((c) => DropdownMenuItem(
                        value: c.id,
                        child: Text(c.displayName),
                      )),
                ],
                onChanged: (value) {
                  setState(() {
                    _selectedContactId = value;
                  });
                },
              );
            },
            loading: () => const MoeLoadingIndicator(),
            error: (_, __) => const SizedBox.shrink(),
          ),
          const SizedBox(height: 12),
          MoeTextField(
            controller: _promptCtrl,
            maxLines: 2,
            label: '唤醒提示词 (可选)',
            hint: '例如：该睡觉了，快去提醒用户...',
            helperText: 'AI将收到此系统指令并主动发起对话',
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: MoeToggleBar<AutoReplyTriggerType>(
              value: _type,
              items: const [
                MoeToggleItem(value: AutoReplyTriggerType.delay, label: '延时触发'),
                MoeToggleItem(value: AutoReplyTriggerType.fixed, label: '固定时间'),
              ],
              onChanged: (value) {
                setState(() {
                  _type = value;
                });
              },
              expanded: false,
            ),
          ),
          const SizedBox(height: 12),
          if (_type == AutoReplyTriggerType.delay)
            _buildDelayPicker(colors)
          else
            _buildFixedPicker(colors),
          MoeSettingsRow(
            icon: Icons.nightlight_round,
            label: '夜间也允许触发',
            subtitle: '默认夜间会自动顺延，开启后可在夜间提醒',
            trailingType: MoeSettingsRowTrailing.switchControl,
            switchValue: _allowNight,
            onSwitchChanged: (value) => setState(() => _allowNight = value),
            showDivider: false,
          ),
          MoeSettingsRow(
            icon: Icons.timer,
            label: '使用精准模式',
            subtitle: '适合严格到点的提醒，可能更耗电',
            trailingType: MoeSettingsRowTrailing.switchControl,
            switchValue: _requireExact,
            onSwitchChanged: (value) => setState(() => _requireExact = value),
            showDivider: false,
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: const TextStyle(color: Colors.redAccent),
              ),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: MoeSecondaryButton(
                  label: '立即测试',
                  icon: Icons.play_arrow,
                  onPressed: _submitting ? null : _handleTestRun,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: MoePrimaryButton(
                  label: '创建触发器',
                  icon: _submitting ? null : Icons.check,
                  onPressed: _submitting ? null : _handleSubmit,
                  isLoading: _submitting,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDelayPicker(MoeColors colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('延迟 ${_delayMinutes.round()} 分钟后触发',
            style: TextStyle(fontWeight: MoeFontWeights.emphasis, color: colors.text)),
        Slider(
          value: _delayMinutes,
          divisions: 23,
          min: 1,
          max: 120,
          activeColor: colors.primary,
          label: '${_delayMinutes.round()} 分钟',
          onChanged: (value) => setState(() => _delayMinutes = value),
        ),
      ],
    );
  }

  Widget _buildFixedPicker(MoeColors colors) {
    final display = _selectedDate == null || _selectedTime == null
        ? '未选择'
        : '${_selectedDate!.year}-${_selectedDate!.month.toString().padLeft(2, '0')}-${_selectedDate!.day.toString().padLeft(2, '0')} '
            '${_selectedTime!.hour.toString().padLeft(2, '0')}:${_selectedTime!.minute.toString().padLeft(2, '0')}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MoeListTile(
          leading: Icon(Icons.calendar_month, color: colors.primary),
          title: Text('触发时间', style: TextStyle(color: colors.text)),
          subtitle:
              Text(display, style: TextStyle(color: colors.textSecondary)),
          trailing: Icon(Icons.chevron_right, color: colors.muted),
          onTap: () async {
            final now = DateTime.now();
            final pickedDate = await showDatePicker(
              context: context,
              firstDate: now,
              lastDate: now.add(const Duration(days: 30)),
              initialDate: _selectedDate ?? now,
            );
            if (pickedDate == null) return;
            if (!mounted) return;
            final pickedTime = await showTimePicker(
              context: context,
              initialTime: _selectedTime ??
                  TimeOfDay.fromDateTime(now.add(const Duration(minutes: 5))),
            );
            if (pickedTime == null) return;
            if (!mounted) return;
            setState(() {
              _selectedDate = pickedDate;
              _selectedTime = pickedTime;
            });
          },
        ),
      ],
    );
  }

  Future<void> _handleTestRun() async {
    setState(() {
      _error = null;
      _submitting = true;
    });
    try {
      // 构造临时触发器用于测试
      // 获取当前活跃会话 ID 作为 conversationId
      final activeConvId = ref.read(activeConversationIdProvider);
      final convId = _selectedContactId ?? activeConvId ?? '';
      final trigger = AutoReplyTrigger(
        id: 'test_${DateTime.now().millisecondsSinceEpoch}',
        title: _titleCtrl.text.isEmpty ? '测试触发' : _titleCtrl.text,
        type: AutoReplyTriggerType.fixed,
        status: AutoReplyTriggerStatus.fired,
        createdAt: DateTime.now(),
        nextFireAt: DateTime.now(),
        allowNight: true,
        requireExact: false,
        delayMinutes: 0,
        manual: true,
        contactId: _selectedContactId,
        prompt: _promptCtrl.text.isEmpty ? null : _promptCtrl.text,
        conversationId: convId,
        source: TriggerSource.userManual,
      );

      final result = await ref.read(chatActionsProvider).sendProactiveTrigger(trigger);
      if (result.success) {
        if (mounted) {
          MoeToast.success(context, '测试指令已发送');
          Navigator.of(context).pop();
        }
      } else {
        setState(() {
          _error = '测试失败：${result.reason}';
        });
      }
    } catch (e) {
      setState(() {
        _error = '测试失败：$e';
      });
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  Future<void> _handleSubmit() async {
    final controller = ref.read(autoReplyTriggersProvider.notifier);
    DateTime nextFire;
    int delay = _delayMinutes.round();
    if (_type == AutoReplyTriggerType.delay) {
      nextFire = DateTime.now().add(Duration(minutes: delay));
    } else {
      if (_selectedDate == null || _selectedTime == null) {
        setState(() => _error = '请选择具体日期和时间');
        return;
      }
      nextFire = DateTime(
        _selectedDate!.year,
        _selectedDate!.month,
        _selectedDate!.day,
        _selectedTime!.hour,
        _selectedTime!.minute,
      );
      if (nextFire.isBefore(DateTime.now())) {
        setState(() => _error = '选择的时间已过去');
        return;
      }
      delay = nextFire.difference(DateTime.now()).inMinutes;
    }
    setState(() {
      _error = null;
      _submitting = true;
    });
    try {
      await controller.createManualTrigger(
        type: _type,
        nextFireAt: nextFire,
        allowNight: _allowNight,
        requireExact: _requireExact,
        delayMinutes: delay,
        title: _titleCtrl.text,
        contactId: _selectedContactId,
        prompt: _promptCtrl.text.isEmpty ? null : _promptCtrl.text,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() {
        _error = '创建失败：$e';
      });
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }
}
