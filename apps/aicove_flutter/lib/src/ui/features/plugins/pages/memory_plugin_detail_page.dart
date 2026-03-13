import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../features/plugins/memory/memory_config.dart';
import '../../../../features/plugins/plugin_providers.dart';
import '../../../../features/settings/app_settings.dart';
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
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载设置失败: $e')),
        data: (appSettings) => _buildBody(config, notifier, appSettings),
      ),
    );
  }

  Widget _buildBody(MemoryConfig config, MemoryPluginConfigNotifier notifier,
      AppSettings appSettings) {
    final chatProviders = appSettings.providers
        .where((p) =>
            p.enabled && appSettings.providerHasModelType(p.id, ModelType.chat))
        .toList();
    final embeddingProviders = appSettings.providers
        .where((p) =>
            p.enabled &&
            appSettings.providerHasModelType(p.id, ModelType.embedding))
        .toList();

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 16),
      children: [
        _buildEnableSection(config, notifier),
        const SizedBox(height: 16),
        if (config.enabled) ...[
          _buildModelSection(
            title: '总结模型',
            icon: Icons.summarize_outlined,
            providers: chatProviders,
            selectedProviderId: config.summarizeProviderId,
            selectedModelName: config.summarizeModelName,
            hint: '用于结构化提取记忆',
            emptyHint: '请先导入聊天模型渠道',
            onChanged: (providerId, modelName) =>
                notifier.setSummarizeModel(providerId, modelName),
            modelType: ModelType.chat,
            appSettings: appSettings,
          ),
          const SizedBox(height: 16),
          _buildModelSection(
            title: 'Embedding 模型',
            icon: Icons.code_outlined,
            providers: embeddingProviders,
            selectedProviderId: config.embeddingProviderId,
            selectedModelName: config.embeddingModelName,
            hint: '用于记忆向量化检索',
            emptyHint: '请先导入 embedding 模型渠道',
            onChanged: (providerId, modelName) =>
                notifier.setEmbeddingModel(providerId, modelName),
            modelType: ModelType.embedding,
            appSettings: appSettings,
          ),
          const SizedBox(height: 16),
          _buildFallbackSection(
              config, notifier, embeddingProviders, appSettings),
          const SizedBox(height: 16),
          _buildRoundSplitSection(config, notifier),
          const SizedBox(height: 16),
          _buildHelpSection(),
        ],
      ],
    );
  }

  Widget _buildEnableSection(
      MemoryConfig config, MemoryPluginConfigNotifier notifier) {
    final colors = context.moeColors;
    return MoeSettingsGroup(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        MoeSettingsRow(
          icon: Icons.memory,
          iconColor: colors.focus,
          label: '启用长期记忆',
          subtitle: '启用后会进行分类总结、画像注入和混合检索',
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
    required AppSettings appSettings,
    required ModelType modelType,
    required String? selectedProviderId,
    required String? selectedModelName,
    required String hint,
    required String emptyHint,
    required void Function(String? providerId, String? modelName) onChanged,
  }) {
    final colors = context.moeColors;
    String? displayText;
    if (selectedProviderId != null && selectedModelName != null) {
      final provider =
          providers.where((p) => p.id == selectedProviderId).firstOrNull;
      if (provider != null) {
        displayText =
            '${provider.displayName ?? provider.id} / $selectedModelName';
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
              appSettings: appSettings,
              modelType: modelType,
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
              style: TextStyle(color: colors.muted, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFallbackSection(
    MemoryConfig config,
    MemoryPluginConfigNotifier notifier,
    List<ProviderAuth> embeddingProviders,
    AppSettings appSettings,
  ) {
    final colors = context.moeColors;
    String? displayText;
    if (config.fallbackEmbeddingProviderId != null &&
        config.fallbackEmbeddingModelName != null) {
      final provider = embeddingProviders
          .where((p) => p.id == config.fallbackEmbeddingProviderId)
          .firstOrNull;
      if (provider != null) {
        displayText =
            '${provider.displayName ?? provider.id} / ${config.fallbackEmbeddingModelName}';
      }
    }

    return MoeSettingsGroup(
      title: '备用 Embedding（可选）',
      margin: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        MoeSettingsRow(
          icon: Icons.backup_outlined,
          iconColor: colors.focus,
          label: '启用备用模型',
          subtitle: '主嵌入服务失败时自动降级',
          trailingType: MoeSettingsRowTrailing.switchControl,
          switchValue: config.fallbackEmbeddingEnabled,
          onSwitchChanged: (value) => notifier.setFallbackEmbeddingModel(
            value,
            config.fallbackEmbeddingProviderId,
            config.fallbackEmbeddingModelName,
          ),
        ),
        if (config.fallbackEmbeddingEnabled && embeddingProviders.isNotEmpty)
          MoeSettingsRow(
            icon: Icons.model_training,
            iconColor: colors.focus,
            label: displayText ?? '点击选择模型',
            labelColor: displayText != null ? colors.text : colors.muted,
            subtitle: '选择备用 embedding 模型',
            trailingType: MoeSettingsRowTrailing.chevron,
            onTap: () => _showModelPicker(
              title: '备用 Embedding',
              providers: embeddingProviders,
              appSettings: appSettings,
              modelType: ModelType.embedding,
              selectedProviderId: config.fallbackEmbeddingProviderId,
              selectedModelName: config.fallbackEmbeddingModelName,
              onChanged: (providerId, modelName) {
                notifier.setFallbackEmbeddingModel(true, providerId, modelName);
              },
            ),
          ),
        if (config.fallbackEmbeddingEnabled && embeddingProviders.isEmpty)
          _buildEmptyHint('请先导入 embedding 渠道'),
      ],
    );
  }

  Widget _buildRoundSplitSection(
      MemoryConfig config, MemoryPluginConfigNotifier notifier) {
    final colors = context.moeColors;
    return MoeSettingsGroup(
      title: '总结策略',
      margin: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        MoeSettingsRow(
          icon: Icons.schedule,
          iconColor: colors.focus,
          label: '分轮阈值',
          subtitle: '单日用户消息超过该值时按 1 小时空档切分轮次',
          trailingType: MoeSettingsRowTrailing.text,
          detailText: '${config.roundSplitThreshold}',
          onTap: () => _showRoundThresholdDialog(config, notifier),
          showDivider: false,
        ),
      ],
    );
  }

  Widget _buildHelpSection() {
    final colors = context.moeColors;
    return MoeSettingsGroup(
      title: '说明',
      margin: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            '新记忆流程：\n'
            '1. 用户发送消息时，后台检查并补做历史未总结内容\n'
            '2. AI 输出分类 + 分层（L1/L2/L3/L4）\n'
            '3. 聊天注入采用“用户画像 + 混合检索记忆”两段式\n\n'
            '建议：总结模型选择 chat，嵌入模型选择 embedding。',
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

  void _showModelPicker({
    required String title,
    required List<ProviderAuth> providers,
    required AppSettings appSettings,
    required ModelType modelType,
    required String? selectedProviderId,
    required String? selectedModelName,
    required void Function(String? providerId, String? modelName) onChanged,
  }) {
    final actions = <MoeSheetAction>[
      MoeSheetAction(
        icon: selectedProviderId == null
            ? Icons.check_circle
            : Icons.circle_outlined,
        label: '未选择',
        onTap: () => onChanged(null, null),
      ),
    ];

    for (final provider in providers) {
      final models = appSettings.getProviderModelsByType(
        provider.id,
        type: modelType,
      );
      final providerName = provider.displayName ?? provider.id;
      for (final model in models) {
        final selected =
            provider.id == selectedProviderId && model == selectedModelName;
        actions.add(
          MoeSheetAction(
            icon: selected ? Icons.check_circle : Icons.circle_outlined,
            label: model,
            subtitle: providerName,
            onTap: () => onChanged(provider.id, model),
          ),
        );
      }
    }

    showMoeActionSheet(
      context: context,
      title: '选择$title',
      actions: actions,
      showCancelButton: true,
    );
  }

  Future<void> _showRoundThresholdDialog(
      MemoryConfig config, MemoryPluginConfigNotifier notifier) async {
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
