import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../features/plugins/plugin_providers.dart';
import '../../../../features/plugins/memory/memory_config.dart';
import '../../../../features/settings/app_settings.dart';

/// 长期记忆插件详细设置页面
///
/// 功能：
/// - 启用/关闭插件
/// - 选择摘要模型（从 chat 类型渠道中选择）
/// - 选择嵌入模型（从 embedding 类型渠道中选择）
/// - 配置备用嵌入模型（降级方案）
class MemoryPluginDetailPage extends ConsumerStatefulWidget {
  const MemoryPluginDetailPage({super.key});

  @override
  ConsumerState<MemoryPluginDetailPage> createState() => _MemoryPluginDetailPageState();
}

class _MemoryPluginDetailPageState extends ConsumerState<MemoryPluginDetailPage> {
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
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载设置失败: $e')),
        data: (appSettings) => _buildBody(config, notifier, appSettings),
      ),
    );
  }

  Widget _buildBody(MemoryConfig config, MemoryPluginConfigNotifier notifier, AppSettings appSettings) {
    // 筛选出 chat 类型和 embedding 类型的渠道
    final chatProviders = appSettings.providers.where((p) =>
      p.enabled && (p.modelType == 'chat' || p.modelType.isEmpty)
    ).toList();

    final embeddingProviders = appSettings.providers.where((p) =>
      p.enabled && p.modelType == 'embedding'
    ).toList();

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 16),
      children: [
        // 启用开关
        _buildEnableSection(config, notifier),
        const SizedBox(height: 16),

        if (config.enabled) ...[
          // 摘要模型选择
          _buildModelSection(
            title: '摘要模型',
            icon: Icons.summarize_outlined,
            providers: chatProviders,
            selectedProviderId: config.summarizeProviderId,
            selectedModelName: config.summarizeModelName,
            hint: '选择用于提取记忆的对话模型',
            emptyHint: '请先在"模型列表"中导入对话模型渠道',
            onChanged: (providerId, modelName) {
              notifier.setSummarizeModel(providerId, modelName);
            },
          ),
          const SizedBox(height: 16),

          // 嵌入模型选择
          _buildModelSection(
            title: '嵌入模型',
            icon: Icons.code_outlined,
            providers: embeddingProviders,
            selectedProviderId: config.embeddingProviderId,
            selectedModelName: config.embeddingModelName,
            hint: '选择用于向量化记忆的嵌入模型',
            emptyHint: '请先在"模型列表"中导入嵌入模型渠道\n(model_type 设为 embedding)',
            onChanged: (providerId, modelName) {
              notifier.setEmbeddingModel(providerId, modelName);
            },
          ),
          const SizedBox(height: 16),

          // 备用嵌入模型
          _buildFallbackSection(config, notifier, embeddingProviders),
          const SizedBox(height: 16),

          // 使用说明
          _buildHelpSection(),
        ],
      ],
    );
  }

  Widget _buildEnableSection(MemoryConfig config, MemoryPluginConfigNotifier notifier) {
    final colors = context.moeColors;

    return MoeSettingsGroup(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        MoeSettingsRow(
          icon: Icons.memory,
          iconColor: colors.focus,
          label: '启用长期记忆',
          subtitle: '让AI记住你的喜好和重要信息',
          trailingType: MoeSettingsRowTrailing.switchControl,
          switchValue: config.enabled,
          onSwitchChanged: (value) => notifier.setEnabled(value),
          showDivider: false,
        ),
      ],
    );
  }

  Widget _buildModelSection({
    required String title,
    required IconData icon,
    required List<ProviderAuth> providers,
    required String? selectedProviderId,
    required String? selectedModelName,
    required String hint,
    required String emptyHint,
    required void Function(String? providerId, String? modelName) onChanged,
  }) {
    final colors = context.moeColors;

    // 获取当前选中的显示文本
    String? displayText;
    if (selectedProviderId != null && selectedModelName != null) {
      final provider = providers.where((p) => p.id == selectedProviderId).firstOrNull;
      if (provider != null) {
        final providerName = provider.displayName ?? provider.id;
        displayText = '$providerName / $selectedModelName';
      }
    }

    return MoeSettingsGroup(
      title: title,
      margin: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        if (providers.isEmpty)
          _buildEmptyHint(emptyHint)
        else
          MoeSettingsRow(
            icon: icon,
            iconColor: colors.focus,
            label: displayText ?? '点击选择模型',
            labelColor: displayText != null ? colors.text : colors.muted,
            subtitle: hint,
            trailingType: MoeSettingsRowTrailing.chevron,
            showDivider: false,
            onTap: () => _showModelPicker(
              title: title,
              providers: providers,
              selectedProviderId: selectedProviderId,
              selectedModelName: selectedModelName,
              onChanged: onChanged,
            ),
          ),
      ],
    );
  }

  Widget _buildEmptyHint(String hint) {
    final colors = context.moeColors;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: colors.muted, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              hint,
              style: TextStyle(
                color: colors.muted,
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 显示模型选择底部弹窗
  void _showModelPicker({
    required String title,
    required List<ProviderAuth> providers,
    required String? selectedProviderId,
    required String? selectedModelName,
    required void Function(String? providerId, String? modelName) onChanged,
  }) {
    // 构建选项列表
    final actions = <MoeSheetAction>[];

    // 添加"未选择"选项
    actions.add(MoeSheetAction(
      icon: selectedProviderId == null ? Icons.check_circle : Icons.circle_outlined,
      label: '未选择',
      onTap: () => onChanged(null, null),
    ));

    // 添加所有模型选项
    for (final provider in providers) {
      final models = provider.visibleModels.isNotEmpty ? provider.visibleModels : provider.models;
      final providerName = provider.displayName ?? provider.id;

      for (final model in models) {
        final isSelected = provider.id == selectedProviderId && model == selectedModelName;
        actions.add(MoeSheetAction(
          icon: isSelected ? Icons.check_circle : Icons.circle_outlined,
          label: model,
          subtitle: providerName,
          onTap: () => onChanged(provider.id, model),
        ));
      }
    }

    showMoeActionSheet(
      context: context,
      title: '选择$title',
      actions: actions,
      showCancelButton: true,
    );
  }

  Widget _buildFallbackSection(
    MemoryConfig config,
    MemoryPluginConfigNotifier notifier,
    List<ProviderAuth> embeddingProviders,
  ) {
    final colors = context.moeColors;

    // 获取当前选中的显示文本
    String? displayText;
    if (config.fallbackEmbeddingProviderId != null && config.fallbackEmbeddingModelName != null) {
      final provider = embeddingProviders.where((p) => p.id == config.fallbackEmbeddingProviderId).firstOrNull;
      if (provider != null) {
        final providerName = provider.displayName ?? provider.id;
        displayText = '$providerName / ${config.fallbackEmbeddingModelName}';
      }
    }

    return MoeSettingsGroup(
      title: '备用嵌入模型（可选）',
      margin: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        MoeSettingsRow(
          icon: Icons.backup_outlined,
          iconColor: colors.focus,
          label: '启用备用模型',
          subtitle: '当主嵌入服务不可用时，自动切换到备用模型',
          trailingType: MoeSettingsRowTrailing.switchControl,
          switchValue: config.fallbackEmbeddingEnabled,
          onSwitchChanged: (value) {
            notifier.setFallbackEmbeddingModel(
              value,
              config.fallbackEmbeddingProviderId,
              config.fallbackEmbeddingModelName,
            );
          },
        ),
        if (config.fallbackEmbeddingEnabled && embeddingProviders.isNotEmpty)
          MoeSettingsRow(
            icon: Icons.model_training,
            iconColor: colors.focus,
            label: displayText ?? '点击选择模型',
            labelColor: displayText != null ? colors.text : colors.muted,
            subtitle: '选择备用嵌入模型',
            trailingType: MoeSettingsRowTrailing.chevron,
            onTap: () => _showModelPicker(
              title: '备用嵌入模型',
              providers: embeddingProviders,
              selectedProviderId: config.fallbackEmbeddingProviderId,
              selectedModelName: config.fallbackEmbeddingModelName,
              onChanged: (providerId, modelName) {
                notifier.setFallbackEmbeddingModel(true, providerId, modelName);
              },
            ),
          ),
        if (config.fallbackEmbeddingEnabled && embeddingProviders.isEmpty)
          _buildEmptyHint('请先导入嵌入模型渠道'),
      ],
    );
  }

  Widget _buildHelpSection() {
    final colors = context.moeColors;

    return MoeSettingsGroup(
      title: '使用说明',
      margin: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            '长期记忆插件会在对话结束时自动提取关键信息（如你的喜好、重要事件等）并存储。\n\n'
            '工作流程：\n'
            '• 摘要模型：负责从对话中提取关键事实\n'
            '• 嵌入模型：将事实转换为向量以便检索\n'
            '• 下次对话时，相关记忆会自动注入到AI的上下文中\n\n'
            '导入嵌入模型：\n'
            '在"模型列表"页面导入渠道时，将 model_type 设为 "embedding"',
            style: TextStyle(
              color: colors.muted,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }
}
