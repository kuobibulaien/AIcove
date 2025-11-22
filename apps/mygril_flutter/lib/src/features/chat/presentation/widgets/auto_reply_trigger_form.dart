import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/tokens.dart';
import '../../data/auto_reply_trigger.dart';
import '../../data/auto_reply_trigger_controller.dart';
import '../../providers2.dart';
import '../../domain/conversation.dart';

Future<void> showCreateAutoReplyTriggerSheet(
  BuildContext context,
  WidgetRef ref,
) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: moeSurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (context) {
      return Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: const _CreateTriggerSheet(),
      );
    },
  );
}

class _CreateTriggerSheet extends ConsumerStatefulWidget {
  const _CreateTriggerSheet();

  @override
  ConsumerState<_CreateTriggerSheet> createState() => _CreateTriggerSheetState();
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
    
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: moeBorderLight,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const Text(
            '创建自定义触发',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _titleCtrl,
            decoration: const InputDecoration(
              labelText: '标题',
              hintText: '例如：晚安提醒',
            ),
          ),
          const SizedBox(height: 12),
          conversationsAsync.when(
            data: (conversations) {
              return DropdownButtonFormField<String>(
                value: _selectedContactId,
                decoration: const InputDecoration(
                  labelText: '指定联系人 (可选)',
                  hintText: '默认使用当前活跃对话',
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
            loading: () => const LinearProgressIndicator(),
            error: (_, __) => const SizedBox.shrink(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _promptCtrl,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: '唤醒提示词 (可选)',
              hintText: '例如：该睡觉了，快去提醒用户...',
              helperText: 'AI将收到此系统指令并主动发起对话',
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<AutoReplyTriggerType>(
              segments: const [
                ButtonSegment(
                  value: AutoReplyTriggerType.delay,
                  label: Text('延时触发'),
                  icon: Icon(Icons.timer_outlined),
                ),
                ButtonSegment(
                  value: AutoReplyTriggerType.fixed,
                  label: Text('固定时间'),
                  icon: Icon(Icons.alarm),
                ),
              ],
              selected: <AutoReplyTriggerType>{_type},
              onSelectionChanged: (value) {
                setState(() {
                  _type = value.first;
                });
              },
            ),
          ),
          const SizedBox(height: 12),
          if (_type == AutoReplyTriggerType.delay) _buildDelayPicker() else _buildFixedPicker(),
          SwitchListTile(
            title: const Text('夜间也允许触发'),
            subtitle: const Text('默认夜间会自动顺延，开启后可在夜间提醒'),
            value: _allowNight,
            onChanged: (value) => setState(() => _allowNight = value),
            activeColor: moePrimary,
          ),
          SwitchListTile(
            title: const Text('使用精准模式'),
            subtitle: const Text('适合严格到点的提醒，可能更耗电'),
            value: _requireExact,
            onChanged: (value) => setState(() => _requireExact = value),
            activeColor: moePrimary,
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
                child: OutlinedButton.icon(
                  onPressed: _submitting ? null : _handleTestRun,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('立即测试'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  onPressed: _submitting ? null : _handleSubmit,
                  icon: _submitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.check),
                  label: const Text('创建触发器'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDelayPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('延迟 ${_delayMinutes.round()} 分钟后触发', style: const TextStyle(fontWeight: FontWeight.w600)),
        Slider(
          value: _delayMinutes,
          divisions: 23,
          min: 1,
          max: 120,
          activeColor: moePrimary,
          label: '${_delayMinutes.round()} 分钟',
          onChanged: (value) => setState(() => _delayMinutes = value),
        ),
      ],
    );
  }

  Widget _buildFixedPicker() {
    final display = _selectedDate == null || _selectedTime == null
        ? '未选择'
        : '${_selectedDate!.year}-${_selectedDate!.month.toString().padLeft(2, '0')}-${_selectedDate!.day.toString().padLeft(2, '0')} '
            '${_selectedTime!.hour.toString().padLeft(2, '0')}:${_selectedTime!.minute.toString().padLeft(2, '0')}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('触发时间'),
          subtitle: Text(display),
          trailing: const Icon(Icons.calendar_month, color: moePrimary),
          onTap: () async {
            final now = DateTime.now();
            final pickedDate = await showDatePicker(
              context: context,
              firstDate: now,
              lastDate: now.add(const Duration(days: 30)),
              initialDate: _selectedDate ?? now,
            );
            if (pickedDate == null) return;
            final pickedTime = await showTimePicker(
              context: context,
              initialTime: _selectedTime ?? TimeOfDay.fromDateTime(now.add(const Duration(minutes: 5))),
            );
            if (pickedTime == null) return;
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
      final trigger = AutoReplyTrigger(
        id: 'test_${DateTime.now().millisecondsSinceEpoch}',
        title: _titleCtrl.text.isEmpty ? '测试触发' : _titleCtrl.text,
        type: AutoReplyTriggerType.fixed,
        status: AutoReplyTriggerStatus.completed,
        createdAt: DateTime.now(),
        nextFireAt: DateTime.now(),
        allowNight: true,
        requireExact: false,
        delayMinutes: 0,
        manual: true,
        contactId: _selectedContactId,
        prompt: _promptCtrl.text.isEmpty ? null : _promptCtrl.text,
      );
      
      await ref.read(chatActionsProvider).sendProactiveTrigger(trigger);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('测试指令已发送')),
        );
        Navigator.of(context).pop();
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
