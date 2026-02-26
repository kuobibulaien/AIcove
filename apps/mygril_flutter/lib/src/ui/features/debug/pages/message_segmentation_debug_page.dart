library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/settings/app_settings.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';

/// 调试工具：消息分段节奏
///
/// 控制流式分段逐条展示时的人为延迟，便于观察和联调。
class MessageSegmentationDebugPage extends ConsumerStatefulWidget {
  const MessageSegmentationDebugPage({super.key});

  @override
  ConsumerState<MessageSegmentationDebugPage> createState() =>
      _MessageSegmentationDebugPageState();
}

class _MessageSegmentationDebugPageState
    extends ConsumerState<MessageSegmentationDebugPage> {
  static const double _kMinDelay = 0.0;
  static const double _kMaxDelay = 3.0;
  static const List<double> _kPresets = <double>[0.0, 0.2, 0.5, 1.0, 1.5];

  bool _initialized = false;
  bool _saving = false;
  double _draftDelaySeconds = 0.0;

  void _ensureDraft(AppSettings settings) {
    if (_initialized) return;
    _draftDelaySeconds = settings.streamSegmentDelaySeconds
        .clamp(_kMinDelay, _kMaxDelay)
        .toDouble();
    _initialized = true;
  }

  String get _delayLabel => '${_draftDelaySeconds.toStringAsFixed(1)}s';

  Future<void> _persist({bool showToast = true}) async {
    setState(() => _saving = true);
    try {
      await ref
          .read(appSettingsProvider.notifier)
          .setStreamSegmentDelaySeconds(_draftDelaySeconds);
      if (mounted && showToast) {
        MoeToast.success(context, '消息分段延迟已保存');
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

  void _applyPreset(double value) {
    setState(() => _draftDelaySeconds = value.clamp(_kMinDelay, _kMaxDelay));
  }

  void _resetToDefault() {
    setState(() => _draftDelaySeconds = 0.0);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final settingsAsync = ref.watch(appSettingsProvider);

    return Scaffold(
      backgroundColor: colors.surface,
      appBar: const MoeAppBar(title: '消息分段', showBackButton: true),
      body: settingsAsync.when(
        loading: () => const Center(child: MoeLoadingIndicator()),
        error: (error, _) => Center(
          child: MoeEmptyState(
            icon: Icons.error_outline,
            title: '加载失败',
            description: '$error',
          ),
        ),
        data: (settings) {
          _ensureDraft(settings);

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (_saving) const LinearProgressIndicator(minHeight: 2),
              if (_saving) const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: MoeG2Decoration(
                  radius: 12,
                  color: colors.surface,
                  border: Border.all(color: colors.borderLight),
                ),
                child: Text(
                  '用途：给“每条分段消息”增加固定间隔，让流式逐条发送更明显。\n'
                  '0.0s 表示关闭延迟；例如 0.5s 表示每条分段之间等待 0.5 秒。',
                  style: TextStyle(fontSize: 13, color: colors.textSecondary),
                ),
              ),
              const SizedBox(height: 12),
              MoeSettingsGroup(
                children: [
                  MoeSettingsRow(
                    icon: Icons.schedule_outlined,
                    label: '当前分段延迟',
                    trailingType: MoeSettingsRowTrailing.text,
                    detailText: _delayLabel,
                    showDivider: false,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: MoeG2Decoration(
                  radius: 12,
                  color: colors.surface,
                  border: Border.all(color: colors.borderLight),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '每条消息延迟：$_delayLabel',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: MoeFontWeights.emphasis,
                        color: colors.text,
                      ),
                    ),
                    Slider(
                      value: _draftDelaySeconds,
                      min: _kMinDelay,
                      max: _kMaxDelay,
                      divisions: ((_kMaxDelay - _kMinDelay) * 10).round(),
                      label: _delayLabel,
                      onChanged: (value) =>
                          setState(() => _draftDelaySeconds = value),
                    ),
                    Text(
                      '建议调试值：0.3s ~ 0.8s',
                      style:
                          TextStyle(fontSize: 12, color: colors.textSecondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final preset in _kPresets)
                    ChoiceChip(
                      label: Text('${preset.toStringAsFixed(1)}s'),
                      selected: (_draftDelaySeconds - preset).abs() < 0.01,
                      onSelected: (_) => _applyPreset(preset),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: MoeSecondaryButton(
                      label: '恢复默认',
                      icon: Icons.restore_rounded,
                      onPressed: _resetToDefault,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: MoePrimaryButton(
                      label: '保存配置',
                      icon: Icons.save_outlined,
                      onPressed: _saving ? null : _persist,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }
}
