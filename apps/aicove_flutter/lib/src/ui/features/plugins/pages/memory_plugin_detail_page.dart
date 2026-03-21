import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/plugins/memory/memory_config.dart';
import '../../../../features/plugins/plugin_providers.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

class MemoryPluginDetailPage extends ConsumerStatefulWidget {
  const MemoryPluginDetailPage({super.key});

  @override
  ConsumerState<MemoryPluginDetailPage> createState() =>
      _MemoryPluginDetailPageState();
}

class _MemoryPluginDetailPageState
    extends ConsumerState<MemoryPluginDetailPage> {
  @override
  Widget build(BuildContext context) {
    final config = ref.watch(memoryPluginConfigProvider);
    final notifier = ref.read(memoryPluginConfigProvider.notifier);
    final appSettingsAsync = ref.watch(appSettingsProvider);
    final colors = context.moeColors;

    return Scaffold(
      backgroundColor: colors.surface,
      appBar: const MoeAppBar(
        title: '长期记忆',
        showBackButton: true,
      ),
      body: appSettingsAsync.when(
        loading: () => const Center(child: MoeLoadingIndicator()),
        error: (error, _) => Center(child: Text('加载设置失败：$error')),
        data: (settings) => _buildBody(
          context,
          config: config,
          notifier: notifier,
          appSettings: settings,
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context, {
    required MemoryConfig config,
    required MemoryPluginConfigNotifier notifier,
    required AppSettings appSettings,
  }) {
    final summaryChoices = _collectAvailableModels(
      appSettings,
      type: ModelType.chat,
    );
    final embeddingChoices = _collectAvailableModels(
      appSettings,
      type: ModelType.embedding,
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        _buildOverviewCard(context, config),
        const SizedBox(height: 16),
        _buildEnableSection(context, config, notifier),
        if (config.enabled) ...[
          const SizedBox(height: 16),
          _buildModelSection(
            context,
            title: '总结模型',
            icon: Icons.summarize_outlined,
            statusText: config.hasSummarizeConfig ? '已配置' : '未配置',
            statusHighlight: config.hasSummarizeConfig,
            description: '必配。用于后台总结、切新话题入库和记忆整理。',
            emptyHint: '请先在模型设置里准备可用的对话模型。',
            currentChoice: _resolveSelectedChoice(
              summaryChoices,
              providerId: config.summarizeProviderId,
              modelName: config.summarizeModelName,
            ),
            choices: summaryChoices,
            allowClear: true,
            onChanged: (choice) => notifier.setSummarizeModel(
              choice?.providerId,
              choice?.modelName,
            ),
          ),
          const SizedBox(height: 16),
          _buildModelSection(
            context,
            title: '嵌入模型',
            icon: Icons.hub_outlined,
            statusText: config.hasEmbeddingConfig ? '已配置' : '可留空',
            statusHighlight: config.hasEmbeddingConfig,
            description: '可选。主要用于 L3 召回；未配置时仍保留 L1 直插、L2 skill 和关键词召回。',
            emptyHint: '当前没有可用的 embedding 模型，留空也可以继续使用记忆功能。',
            currentChoice: _resolveSelectedChoice(
              embeddingChoices,
              providerId: config.embeddingProviderId,
              modelName: config.embeddingModelName,
            ),
            choices: embeddingChoices,
            allowClear: true,
            onChanged: (choice) => notifier.setEmbeddingModel(
              choice?.providerId,
              choice?.modelName,
            ),
          ),
          const SizedBox(height: 16),
          _buildInjectionSection(context),
          const SizedBox(height: 16),
          _buildTriggerSection(context, config, notifier),
          const SizedBox(height: 16),
          _buildRuleSection(context),
        ],
      ],
    );
  }

  Widget _buildOverviewCard(BuildContext context, MemoryConfig config) {
    final colors = context.moeColors;
    final summaryReady = config.hasSummarizeConfig;
    final embeddingReady = config.hasEmbeddingConfig;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: MoeG2Decoration(
        radius: MoeSmoothRadii.lg,
        color: colors.panel,
        border: Border.all(color: colors.borderLight, width: borderWidth),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: MoeG2Decoration(
                  radius: MoeSmoothRadii.md,
                  color: colors.focus.withOpacity(0.12),
                ),
                child: Icon(Icons.psychology_alt_outlined,
                    color: colors.focus, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '角色专属记忆工作台',
                      style: TextStyle(
                        color: colors.text,
                        fontSize: 17,
                        fontWeight: MoeFontWeights.emphasis,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '每个角色一套独立记忆库，L1 直插，L2 走 skill，L3 做召回。',
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 13,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildStatusChip(
                context,
                label: summaryReady ? '总结模型已就绪' : '总结模型待配置',
                highlighted: summaryReady,
              ),
              _buildStatusChip(
                context,
                label: embeddingReady ? 'L3 召回增强已开启' : 'L3 召回走可选嵌入',
                highlighted: embeddingReady,
              ),
              _buildStatusChip(
                context,
                label: '统一时间前缀',
                highlighted: true,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEnableSection(
    BuildContext context,
    MemoryConfig config,
    MemoryPluginConfigNotifier notifier,
  ) {
    final colors = context.moeColors;
    return MoeSettingsGroup(
      children: [
        MoeSettingsRow(
          icon: Icons.memory_outlined,
          iconColor: colors.focus,
          label: '启用长期记忆',
          subtitle: '开启后会按 24 小时保护期、角色隔离和分层记忆规则运行。',
          trailingType: MoeSettingsRowTrailing.switchControl,
          switchValue: config.enabled,
          onSwitchChanged: (value) => notifier.setEnabled(value),
          showDivider: false,
        ),
      ],
    );
  }

  Widget _buildModelSection(
    BuildContext context, {
    required String title,
    required IconData icon,
    required String statusText,
    required bool statusHighlight,
    required String description,
    required String emptyHint,
    required _ModelChoice? currentChoice,
    required List<_ModelChoice> choices,
    required bool allowClear,
    required ValueChanged<_ModelChoice?> onChanged,
  }) {
    final colors = context.moeColors;
    return MoeSettingsGroup(
      title: title,
      children: [
        MoeSettingsRow(
          icon: icon,
          iconColor: colors.focus,
          label: currentChoice?.displayLabel ?? '点击选择模型',
          labelColor: currentChoice != null ? colors.text : colors.muted,
          subtitle: description,
          trailingType: MoeSettingsRowTrailing.chevron,
          showDivider: false,
          onTap: choices.isEmpty
              ? null
              : () => _showModelPicker(
                    title: title,
                    choices: choices,
                    currentChoice: currentChoice,
                    allowClear: allowClear,
                    onChanged: onChanged,
                  ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Row(
            children: [
              Icon(
                statusHighlight ? Icons.check_circle : Icons.info_outline,
                size: 16,
                color: statusHighlight ? colors.primary : colors.muted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  choices.isEmpty ? emptyHint : statusText,
                  style: TextStyle(
                    color:
                        statusHighlight ? colors.primary : colors.textSecondary,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildInjectionSection(BuildContext context) {
    return MoeSettingsGroup(
      title: 'Prompt 注入方式',
      children: const [
        _MemoryRuleTile(
          icon: Icons.push_pin_outlined,
          title: 'L1 用户攻略',
          description: '直接插入 prompt。用于性格、红线、稳定偏好等高确定信息。',
        ),
        _MemoryRuleTile(
          icon: Icons.auto_awesome_outlined,
          title: 'L2 记忆技能',
          description: '以 skill 索引 + 命中详情注入。先给标题、时间和触发线索，再展开详细内容。',
        ),
        _MemoryRuleTile(
          icon: Icons.history_edu_outlined,
          title: 'L3 日记回忆',
          description: '按查询召回注入。嵌入模型主要服务这一层，未配置时退化为关键词召回。',
        ),
      ],
    );
  }

  Widget _buildTriggerSection(
    BuildContext context,
    MemoryConfig config,
    MemoryPluginConfigNotifier notifier,
  ) {
    final colors = context.moeColors;
    return MoeSettingsGroup(
      title: '触发机制',
      children: [
        const _MemoryRuleTile(
          icon: Icons.schedule_outlined,
          title: '24 小时保护期',
          description: '用户发消息时，后台只检查 24 小时之前且尚未总结的消息，避免打断当前聊天。',
        ),
        const _MemoryRuleTile(
          icon: Icons.alt_route_outlined,
          title: '新话题强制入库',
          description: '开始新话题前，先把当前角色旧上下文做一次手动总结，再切换上下文边界。',
        ),
        const _MemoryRuleTile(
          icon: Icons.delete_sweep_outlined,
          title: '清空聊天联动清空记忆',
          description:
              '清空聊天记录时，会同步清空当前角色的 memories、diaries 和 summarization records。',
        ),
        MoeSettingsRow(
          icon: Icons.tune_outlined,
          iconColor: colors.focus,
          label: '分轮阈值',
          subtitle: '单日用户消息超过该值时，按 1 小时空档切分轮次。',
          trailingType: MoeSettingsRowTrailing.text,
          detailText: '${config.roundSplitThreshold}',
          showDivider: false,
          onTap: () => _showRoundThresholdDialog(config, notifier),
        ),
      ],
    );
  }

  Widget _buildRuleSection(BuildContext context) {
    final colors = context.moeColors;
    return MoeSettingsGroup(
      title: '当前规则',
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '所有进入 prompt 的记忆都会补时间前缀，让模型知道事件发生在什么时候、距离现在多久。',
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'L1 更偏“稳定画像”，L2 更偏“事件技能”，L3 更偏“可回忆日记”。',
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStatusChip(
    BuildContext context, {
    required String label,
    required bool highlighted,
  }) {
    final colors = context.moeColors;
    final color = highlighted ? colors.primary : colors.muted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: MoeG2Decoration(
        radius: MoeSmoothRadii.sm,
        color: color.withOpacity(0.12),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: MoeFontWeights.emphasis,
        ),
      ),
    );
  }

  List<_ModelChoice> _collectAvailableModels(
    AppSettings appSettings, {
    required ModelType type,
  }) {
    final result = <_ModelChoice>[];
    for (final provider in appSettings.providers) {
      if (!provider.enabled) continue;
      final visible = appSettings.getProviderVisibleModelsByType(
        provider.id,
        type: type,
      );
      final fallback = appSettings.getProviderModelsByType(
        provider.id,
        type: type,
      );
      final candidates = visible.isNotEmpty ? visible : fallback;
      for (final modelName in candidates) {
        result.add(
          _ModelChoice(
            providerId: provider.id,
            providerName: provider.displayName ?? provider.id,
            modelName: modelName,
          ),
        );
      }
    }
    return result;
  }

  _ModelChoice? _resolveSelectedChoice(
    List<_ModelChoice> choices, {
    required String? providerId,
    required String? modelName,
  }) {
    if (providerId == null || providerId.isEmpty) return null;
    if (modelName == null || modelName.isEmpty) return null;
    for (final choice in choices) {
      if (choice.providerId == providerId && choice.modelName == modelName) {
        return choice;
      }
    }
    return _ModelChoice(
      providerId: providerId,
      providerName: providerId,
      modelName: modelName,
    );
  }

  void _showModelPicker({
    required String title,
    required List<_ModelChoice> choices,
    required _ModelChoice? currentChoice,
    required bool allowClear,
    required ValueChanged<_ModelChoice?> onChanged,
  }) {
    final actions = <MoeSheetAction>[];
    if (allowClear) {
      actions.add(
        MoeSheetAction(
          icon: currentChoice == null
              ? Icons.check_circle
              : Icons.circle_outlined,
          label: '未选择',
          subtitle: '清空当前配置',
          onTap: () => onChanged(null),
        ),
      );
    }

    for (final choice in choices) {
      final selected = currentChoice != null &&
          currentChoice.providerId == choice.providerId &&
          currentChoice.modelName == choice.modelName;
      actions.add(
        MoeSheetAction(
          icon: selected ? Icons.check_circle : Icons.circle_outlined,
          label: choice.modelName,
          subtitle: choice.providerName,
          onTap: () => onChanged(choice),
        ),
      );
    }

    showMoeActionSheet(
      context: context,
      title: '选择$title',
      actions: actions,
      showCancelButton: true,
    );
  }

  Future<void> _showRoundThresholdDialog(
    MemoryConfig config,
    MemoryPluginConfigNotifier notifier,
  ) async {
    final controller =
        TextEditingController(text: config.roundSplitThreshold.toString());
    final value = await showDialog<int>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('设置分轮阈值'),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(hintText: '建议 20'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop(int.tryParse(controller.text.trim()));
              },
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
    if (value != null) {
      await notifier.setRoundSplitThreshold(value);
    }
  }
}

class _ModelChoice {
  final String providerId;
  final String providerName;
  final String modelName;

  const _ModelChoice({
    required this.providerId,
    required this.providerName,
    required this.modelName,
  });

  String get displayLabel => '$providerName / $modelName';
}

class _MemoryRuleTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;

  const _MemoryRuleTile({
    required this.icon,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: MoeG2Decoration(
              radius: MoeSmoothRadii.sm,
              color: colors.focus.withOpacity(0.12),
            ),
            child: Icon(icon, size: 18, color: colors.focus),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 14,
                    fontWeight: MoeFontWeights.emphasis,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 12,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
