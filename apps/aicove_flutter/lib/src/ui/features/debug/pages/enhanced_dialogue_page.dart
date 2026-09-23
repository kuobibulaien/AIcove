library;

import 'package:aicove_flutter/src/ui/theme/moe_interaction_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/settings/app_settings.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';

/// 调试工具：增强对话
///
/// 用于配置“增强生成”的上下文拼接规则。
class EnhancedDialoguePage extends ConsumerStatefulWidget {
  const EnhancedDialoguePage({super.key});

  @override
  ConsumerState<EnhancedDialoguePage> createState() =>
      _EnhancedDialoguePageState();
}

class _EnhancedDialoguePageState extends ConsumerState<EnhancedDialoguePage>
    with MoeAutoSaveState<EnhancedDialoguePage> {
  EnhancedDialogueSettings? _draft;
  bool _initialized = false;

  final TextEditingController _systemPromptController = TextEditingController();
  final TextEditingController _bootstrapController = TextEditingController();

  @override
  void dispose() {
    _systemPromptController.dispose();
    _bootstrapController.dispose();
    super.dispose();
  }

  void _ensureDraft(AppSettings settings) {
    if (_initialized) return;
    _draft = settings.enhancedDialogueSettings;
    _systemPromptController.text = _draft!.systemPrompt;
    _bootstrapController.text = _draft!.bootstrapUserMessage;
    _initialized = true;
    autoSave.configure(
      save: _persist,
      snapshot: () => moeAutoSaveSignature(_draft!.toJson()),
      fields: [_systemPromptController, _bootstrapController],
    );
  }

  Future<void> _persist() async {
    await ref
        .read(appSettingsProvider.notifier)
        .updateEnhancedDialogueSettings(_draft!);
  }

  void _updateDraft(EnhancedDialogueSettings next) {
    setState(() => _draft = next);
  }

  Future<void> _toggleEnabled(bool enabled) async {
    final current = _draft ?? const EnhancedDialogueSettings();
    final next = current.copyWith(enabled: enabled);
    setState(() => _draft = next);
    await autoSave.flush();
  }

  void _resetToDefault() {
    const next = EnhancedDialogueSettings();
    _systemPromptController.text = next.systemPrompt;
    _bootstrapController.text = next.bootstrapUserMessage;
    setState(() => _draft = next);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final settingsAsync = ref.watch(appSettingsProvider);

    return autoSavePage(
      MoePageScaffold(
        extendBodyBehindAppBar: true,
        backgroundColor: colors.surface,
        appBar: const MoeAppBar(title: '增强对话', showBackButton: true),
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
            final draft = _draft ?? settings.enhancedDialogueSettings;

            return Builder(
              builder: (context) => ListView(
                padding: moeUnderBarPadding(context, EdgeInsets.all(16)),
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: MoeG2Decoration(
                      radius: 12,
                      color: colors.surface,
                      border: Border.all(color: colors.borderLight),
                    ),
                    child: Text(
                      '开启后，消息菜单会出现“增强生成”。增强生成会用你配置的系统提示词 + 第一条任务消息 + 最近N轮上下文来重新生成回复。',
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  MoeSettingsGroup(
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    children: [
                      MoeSettingsRow(
                        icon: Icons.auto_awesome_outlined,
                        label: '启用增强生成',
                        subtitle: draft.enabled ? '已开启（消息菜单可见）' : '已关闭（消息菜单隐藏）',
                        trailingType: MoeSettingsRowTrailing.switchControl,
                        switchValue: draft.enabled,
                        onSwitchChanged: _toggleEnabled,
                        showDivider: false,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  MoeTextField(
                    label: '增强系统提示词',
                    hint: '输入增强生成使用的系统提示词',
                    controller: _systemPromptController,
                    maxLines: 8,
                    minLines: 6,
                    onChanged: (value) =>
                        _updateDraft(draft.copyWith(systemPrompt: value)),
                  ),
                  const SizedBox(height: 12),
                  MoeTextField(
                    label: '第一条用户消息（任务说明）',
                    hint: '会插在最近对话前面，作为任务派发消息',
                    controller: _bootstrapController,
                    maxLines: 6,
                    minLines: 4,
                    onChanged: (value) => _updateDraft(
                      draft.copyWith(bootstrapUserMessage: value),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: MoeG2Decoration(
                      radius: 12,
                      color: colors.surface,
                      border: Border.all(color: colors.borderLight),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '最近轮数：${draft.recentRounds}',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: MoeFontWeights.emphasis,
                            color: colors.text,
                          ),
                        ),
                        Slider(
                          overlayColor: moeInteractionOverlay,
                          value: draft.recentRounds.toDouble(),
                          min: 1,
                          max: 20,
                          divisions: 19,
                          label: '${draft.recentRounds}',
                          onChanged: (value) => _updateDraft(
                            draft.copyWith(recentRounds: value.round()),
                          ),
                        ),
                        Text(
                          '默认建议 3 轮。这里的“轮”按用户消息计数，会包含当前要重生成的这一轮。',
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.textSecondary,
                          ),
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
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '提示：增强生成仍走正常消息生成链路，支持工具调用和多模态；只改变上下文拼接方式。',
                    style: TextStyle(fontSize: 12, color: colors.textSecondary),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
