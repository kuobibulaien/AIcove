library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/settings/app_settings.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';

/// 调试工具：调用超时管理
///
/// 用于配置模型/工具默认超时。生图路径切换已迁移到绘图设置。
class CallFlowManagementPage extends ConsumerStatefulWidget {
  const CallFlowManagementPage({super.key});

  @override
  ConsumerState<CallFlowManagementPage> createState() =>
      _CallFlowManagementPageState();
}

class _CallFlowManagementPageState
    extends ConsumerState<CallFlowManagementPage> {
  CallFlowSettings? _draft;
  bool _initialized = false;
  bool _saving = false;

  void _ensureDraft(AppSettings settings) {
    if (_initialized) return;
    _draft = settings.callFlowSettings;
    _initialized = true;
  }

  Future<void> _persist({bool showToast = true}) async {
    final draft = _draft;
    if (draft == null) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(appSettingsProvider.notifier)
          .updateCallFlowSettings(draft);
      if (mounted && showToast) {
        MoeToast.success(context, '调用超时设置已保存');
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

  void _resetToDefault() {
    final current = _draft ?? const CallFlowSettings();
    const defaults = CallFlowSettings();
    setState(
      () => _draft = current.copyWith(
        modelTimeoutSeconds: defaults.modelTimeoutSeconds,
        toolTimeoutSeconds: defaults.toolTimeoutSeconds,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final settingsAsync = ref.watch(appSettingsProvider);

    return Scaffold(
      backgroundColor: colors.surface,
      appBar: const MoeAppBar(title: '调用超时管理', showBackButton: true),
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
          final draft = _draft ?? settings.callFlowSettings;

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
                  '这里只调试模型请求和工具执行超时。\n'
                  '生图路径切换已经移动到「绘图设置」，自动档会在满足视觉 + 工具调用时走 draw_image 审图链路，否则改走 <image> 标签直连链路。',
                  style: TextStyle(fontSize: 13, color: colors.textSecondary),
                ),
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
                      '模型默认超时：${draft.modelTimeoutSeconds}s',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: MoeFontWeights.emphasis,
                        color: colors.text,
                      ),
                    ),
                    Slider(
                      value: draft.modelTimeoutSeconds.toDouble(),
                      min: CallFlowSettings.minModelTimeoutSeconds.toDouble(),
                      max: CallFlowSettings.maxModelTimeoutSeconds.toDouble(),
                      divisions: CallFlowSettings.maxModelTimeoutSeconds -
                          CallFlowSettings.minModelTimeoutSeconds,
                      label: '${draft.modelTimeoutSeconds}s',
                      onChanged: (value) => setState(
                        () => _draft = draft.copyWith(
                          modelTimeoutSeconds: value.round(),
                        ),
                      ),
                    ),
                    Text(
                      '作用：限制每轮模型请求等待时间。超时后本轮失败。',
                      style:
                          TextStyle(fontSize: 12, color: colors.textSecondary),
                    ),
                  ],
                ),
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
                      '工具默认超时：${draft.toolTimeoutSeconds}s',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: MoeFontWeights.emphasis,
                        color: colors.text,
                      ),
                    ),
                    Slider(
                      value: draft.toolTimeoutSeconds.toDouble(),
                      min: CallFlowSettings.minToolTimeoutSeconds.toDouble(),
                      max: CallFlowSettings.maxToolTimeoutSeconds.toDouble(),
                      divisions: CallFlowSettings.maxToolTimeoutSeconds -
                          CallFlowSettings.minToolTimeoutSeconds,
                      label: '${draft.toolTimeoutSeconds}s',
                      onChanged: (value) => setState(
                        () => _draft = draft.copyWith(
                          toolTimeoutSeconds: value.round(),
                        ),
                      ),
                    ),
                    Text(
                      '作用：限制单个工具调用等待时间。自动档命中稳定链路时主要影响 draw_image 及其他工具执行；快速档下生图改走 <image> 标签链路，这里主要影响非生图工具。',
                      style:
                          TextStyle(fontSize: 12, color: colors.textSecondary),
                    ),
                  ],
                ),
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
                      label: '保存超时',
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
