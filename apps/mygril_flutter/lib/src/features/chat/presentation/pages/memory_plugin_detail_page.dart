import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/tokens.dart';
import '../../../plugins/plugin_providers.dart';
import '../../../plugins/memory/memory_config.dart';
import '../../../settings/app_settings.dart';

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

    return Scaffold(
      backgroundColor: moeSurface,
      appBar: AppBar(
        backgroundColor: moeSurface,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: moeText),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          '长期记忆',
          style: TextStyle(
            color: moeText,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
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

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 启用开关
          _buildEnableSwitch(config, notifier),
          const SizedBox(height: 24),

          if (config.enabled) ...[
            // 摘要模型选择
            _buildSectionTitle('摘要模型', Icons.summarize_outlined),
            const SizedBox(height: 8),
            _buildModelSelector(
              providers: chatProviders,
              selectedProviderId: config.summarizeProviderId,
              selectedModelName: config.summarizeModelName,
              hint: '选择用于提取记忆的对话模型',
              emptyHint: '请先在"模型列表"中导入对话模型渠道',
              onChanged: (providerId, modelName) {
                notifier.setSummarizeModel(providerId, modelName);
              },
            ),
            const SizedBox(height: 24),

            // 嵌入模型选择
            _buildSectionTitle('嵌入模型', Icons.code_outlined),
            const SizedBox(height: 8),
            _buildModelSelector(
              providers: embeddingProviders,
              selectedProviderId: config.embeddingProviderId,
              selectedModelName: config.embeddingModelName,
              hint: '选择用于向量化记忆的嵌入模型',
              emptyHint: '请先在"模型列表"中导入嵌入模型渠道\n(model_type 设为 embedding)',
              onChanged: (providerId, modelName) {
                notifier.setEmbeddingModel(providerId, modelName);
              },
            ),
            const SizedBox(height: 24),

            // 备用嵌入模型
            _buildFallbackSection(config, notifier, embeddingProviders),
            const SizedBox(height: 24),

            // 使用说明
            _buildHelpSection(),
          ],
        ],
      ),
    );
  }

  Widget _buildEnableSwitch(MemoryConfig config, MemoryPluginConfigNotifier notifier) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: moePanel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: moeBorder),
      ),
      child: Row(
        children: [
          Icon(Icons.memory, color: moePrimary, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '启用长期记忆',
                  style: TextStyle(
                    color: moeText,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '让AI记住你的喜好和重要信息',
                  style: TextStyle(
                    color: moeTextSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: config.enabled,
            onChanged: (value) => notifier.setEnabled(value),
            activeColor: moePrimary,
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, color: moePrimary, size: 20),
        const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            color: moeText,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildModelSelector({
    required List<ProviderAuth> providers,
    required String? selectedProviderId,
    required String? selectedModelName,
    required String hint,
    required String emptyHint,
    required void Function(String? providerId, String? modelName) onChanged,
  }) {
    if (providers.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: moePanel.withOpacity(0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: moeBorder.withOpacity(0.5)),
        ),
        child: Row(
          children: [
            Icon(Icons.info_outline, color: moeTextSecondary, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                emptyHint,
                style: TextStyle(
                  color: moeTextSecondary,
                  fontSize: 14,
                ),
              ),
            ),
          ],
        ),
      );
    }

    // 构建下拉选项：渠道 + 模型
    final items = <DropdownMenuItem<String>>[];
    items.add(DropdownMenuItem<String>(
      value: null,
      child: Text('未选择', style: TextStyle(color: moeMuted, fontSize: 14)),
    ));

    for (final provider in providers) {
      for (final model in provider.visibleModels.isNotEmpty ? provider.visibleModels : provider.models) {
        final value = '${provider.id}::$model';
        final displayName = provider.displayName ?? provider.id;
        items.add(DropdownMenuItem<String>(
          value: value,
          child: Text(
            '$displayName / $model',
            style: TextStyle(color: moeText, fontSize: 14),
            overflow: TextOverflow.ellipsis,
          ),
        ));
      }
    }

    // 当前选中的值
    String? currentValue;
    if (selectedProviderId != null && selectedModelName != null) {
      currentValue = '$selectedProviderId::$selectedModelName';
      // 确保值在列表中存在
      if (!items.any((item) => item.value == currentValue)) {
        currentValue = null;
      }
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: moePanel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: moeBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            hint,
            style: TextStyle(
              color: moeTextSecondary,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: currentValue,
            isExpanded: true,
            decoration: InputDecoration(
              filled: true,
              fillColor: moeSurface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: moeBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: moeBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: moePrimary, width: 2),
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            items: items,
            onChanged: (value) {
              if (value == null) {
                onChanged(null, null);
              } else {
                final parts = value.split('::');
                if (parts.length == 2) {
                  onChanged(parts[0], parts[1]);
                }
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildFallbackSection(
    MemoryConfig config, 
    MemoryPluginConfigNotifier notifier,
    List<ProviderAuth> embeddingProviders,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: moePanel.withOpacity(0.7),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: moeBorder.withOpacity(0.7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.backup_outlined, color: moePrimary, size: 20),
              const SizedBox(width: 8),
              Text(
                '备用嵌入模型（可选）',
                style: TextStyle(
                  color: moeText,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Switch(
                value: config.fallbackEmbeddingEnabled,
                onChanged: (value) {
                  notifier.setFallbackEmbeddingModel(
                    value,
                    config.fallbackEmbeddingProviderId,
                    config.fallbackEmbeddingModelName,
                  );
                },
                activeColor: moePrimary,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '当主嵌入服务不可用时，自动切换到备用模型',
            style: TextStyle(
              color: moeTextSecondary,
              fontSize: 13,
            ),
          ),
          if (config.fallbackEmbeddingEnabled) ...[
            const SizedBox(height: 16),
            _buildModelSelector(
              providers: embeddingProviders,
              selectedProviderId: config.fallbackEmbeddingProviderId,
              selectedModelName: config.fallbackEmbeddingModelName,
              hint: '选择备用嵌入模型',
              emptyHint: '请先导入嵌入模型渠道',
              onChanged: (providerId, modelName) {
                notifier.setFallbackEmbeddingModel(true, providerId, modelName);
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHelpSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: moePanel.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: moeBorder.withOpacity(0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.help_outline, color: moePrimary, size: 20),
              const SizedBox(width: 8),
              Text(
                '使用说明',
                style: TextStyle(
                  color: moeText,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '长期记忆插件会在对话结束时自动提取关键信息（如你的喜好、重要事件等）并存储。\n\n'
            '工作流程：\n'
            '• 摘要模型：负责从对话中提取关键事实\n'
            '• 嵌入模型：将事实转换为向量以便检索\n'
            '• 下次对话时，相关记忆会自动注入到AI的上下文中\n\n'
            '导入嵌入模型：\n'
            '在"模型列表"页面导入渠道时，将 model_type 设为 "embedding"',
            style: TextStyle(
              color: moeTextSecondary,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}
