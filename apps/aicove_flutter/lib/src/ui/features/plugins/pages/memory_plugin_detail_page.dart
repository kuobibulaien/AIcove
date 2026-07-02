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
      appBar: const MoeAppBar(title: '长期记忆', showBackButton: true),
      body: appSettingsAsync.when(
        loading: () => const Center(child: MoeLoadingIndicator()),
        error: (error, _) => Center(child: Text('加载设置失败：$error')),
        data: (settings) =>
            _buildBody(config: config, notifier: notifier, appSettings: settings),
      ),
    );
  }

  Widget _buildBody({
    required MemoryConfig config,
    required MemoryPluginConfigNotifier notifier,
    required AppSettings appSettings,
  }) {
    final summaryChoices =
        _collectAvailableModels(appSettings, type: ModelType.chat);
    final embeddingChoices =
        _collectAvailableModels(appSettings, type: ModelType.embedding);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        MoeSettingsGroup(
          children: [
            MoeSettingsRow(
              icon: Icons.psychology_outlined,
              label: '启用长期记忆',
              subtitle: '会话结束后自动总结并入库',
              trailingType: MoeSettingsRowTrailing.switchControl,
              switchValue: config.enabled,
              onSwitchChanged: notifier.setEnabled,
              showDivider: false,
            ),
          ],
        ),
        if (config.enabled) ...[
          const SizedBox(height: 16),
          MoeSettingsGroup(
            title: '总结模型',
            children: [
              MoeSettingsRow(
                icon: Icons.summarize_outlined,
                label: '点击选择模型',
                subtitle: _modelSubtitle(
                  config.summarizeProviderId,
                  config.summarizeModelName,
                  fallback: '未配置',
                ),
                showDivider: false,
                onTap: () => _showModelPicker(
                  title: '总结模型',
                  choices: summaryChoices,
                  currentChoice: _resolveSelectedChoice(
                    summaryChoices,
                    providerId: config.summarizeProviderId,
                    modelName: config.summarizeModelName,
                  ),
                  allowClear: true,
                  onChanged: (choice) => notifier.setSummarizeModel(
                    choice?.providerId,
                    choice?.modelName,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          MoeSettingsGroup(
            title: '嵌入模型（可选）',
            children: [
              MoeSettingsRow(
                icon: Icons.hub_outlined,
                label: '点击选择模型',
                subtitle: _modelSubtitle(
                  config.embeddingProviderId,
                  config.embeddingModelName,
                  fallback: '未配置（仍可使用关键词召回）',
                ),
                showDivider: false,
                onTap: () => _showModelPicker(
                  title: '嵌入模型',
                  choices: embeddingChoices,
                  currentChoice: _resolveSelectedChoice(
                    embeddingChoices,
                    providerId: config.embeddingProviderId,
                    modelName: config.embeddingModelName,
                  ),
                  allowClear: true,
                  onChanged: (choice) => notifier.setEmbeddingModel(
                    choice?.providerId,
                    choice?.modelName,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  String _modelSubtitle(String? providerId, String? modelName,
      {required String fallback}) {
    if (providerId == null || providerId.isEmpty) return fallback;
    if (modelName == null || modelName.isEmpty) return fallback;
    return '$providerId / $modelName';
  }

  List<_ModelChoice> _collectAvailableModels(
    AppSettings appSettings, {
    required ModelType type,
  }) {
    final result = <_ModelChoice>[];
    for (final provider in appSettings.providers) {
      if (!provider.enabled) continue;
      final visible =
          appSettings.getProviderVisibleModelsByType(provider.id, type: type);
      final fallback =
          appSettings.getProviderModelsByType(provider.id, type: type);
      final candidates = visible.isNotEmpty ? visible : fallback;
      for (final modelName in candidates) {
        result.add(_ModelChoice(
          providerId: provider.id,
          providerName: provider.displayName ?? provider.id,
          modelName: modelName,
        ));
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
      actions.add(MoeSheetAction(
        icon: currentChoice == null
            ? Icons.check_circle
            : Icons.circle_outlined,
        label: '未选择',
        subtitle: '清空当前配置',
        onTap: () => onChanged(null),
      ));
    }
    for (final choice in choices) {
      final selected = currentChoice != null &&
          currentChoice.providerId == choice.providerId &&
          currentChoice.modelName == choice.modelName;
      actions.add(MoeSheetAction(
        icon: selected ? Icons.check_circle : Icons.circle_outlined,
        label: choice.modelName,
        subtitle: choice.providerName,
        onTap: () => onChanged(choice),
      ));
    }
    showMoeActionSheet(
      context: context,
      title: '选择$title',
      actions: actions,
      showCancelButton: true,
    );
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
}
