/// AutoReplyDialogs - 自动回复相关对话框
///
/// 从 auto_reply_settings_page.dart 提取，处理模型选择和提示词编辑。
///
/// 更新记录：
/// - 2025-12-31: 从 auto_reply_settings_page.dart 提取，改用底部弹窗
library;

import 'package:flutter/material.dart';

import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../features/settings/app_settings.dart';

/// 模型选择选项
class ModelOption {
  final String? model;
  final String? provider;
  final String displayName;
  final String subtitle;

  const ModelOption({
    required this.model,
    required this.provider,
    required this.displayName,
    required this.subtitle,
  });
}

/// 显示模型选择器底部弹窗
Future<ModelOption?> showAnalyzerModelPicker({
  required BuildContext context,
  required AutoReplySettings draft,
  required AppSettings settings,
}) async {
  // 构建可用模型列表
  final availableModels = <ModelOption>[];

  // 添加 "使用默认模型" 选项
  final defaultModelLabel =
      settings.getModelDisplayName(settings.defaultModelName);
  final defaultModelProvider =
      settings.getModelProviderId(settings.defaultModelName);
  final defaultSubtitle =
      defaultModelProvider == null || defaultModelProvider.isEmpty
          ? defaultModelLabel
          : '$defaultModelLabel ($defaultModelProvider)';

  availableModels.add(ModelOption(
    model: null,
    provider: null,
    displayName: '使用默认对话模型',
    subtitle: defaultSubtitle,
  ));

  // 从所有已加载模型中提取 chat 类型，避免把 embedding/tts 混进来。
  for (final provider in settings.providers) {
    if (!provider.enabled) continue;
    for (final model in settings.getProviderModelsByType(
      provider.id,
      type: ModelType.chat,
    )) {
      final modelRef = settings.buildModelRef(provider.id, model);
      availableModels.add(ModelOption(
        model: model,
        provider: provider.id,
        displayName: settings.getModelDisplayName(modelRef),
        subtitle: provider.id,
      ));
    }
  }

  return showMoeBottomSheet<ModelOption>(
    context: context,
    title: '选择 AI 管家模型',
    showCloseButton: true,
    builder: (context) => ListView.builder(
      shrinkWrap: true,
      itemCount: availableModels.length,
      itemBuilder: (context, index) {
        final option = availableModels[index];
        String? currentProvider = draft.analyzerProvider;
        if (draft.analyzerModel?.isNotEmpty == true &&
            (currentProvider == null || currentProvider.isEmpty)) {
          currentProvider = settings.getModelProviderId(draft.analyzerModel!);
        }
        final isUsingDefault =
            option.model == null && draft.analyzerModel == null;
        final isSelected = isUsingDefault ||
            (option.model == draft.analyzerModel &&
                option.provider == currentProvider);
        final colors = context.moeColors;

        return ListTile(
          leading: Icon(
            isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
            color: isSelected ? colors.primary : colors.muted,
          ),
          title: Text(option.displayName),
          subtitle:
              Text(option.subtitle, style: TextStyle(color: colors.muted)),
          onTap: () => Navigator.pop(context, option),
        );
      },
    ),
  );
}

/// 编辑提示词后自动返回最新内容。
Future<String?> showEditPromptSheet(
    {required BuildContext context, required String currentPrompt}) async {
  var result = currentPrompt;
  await showMoeAutoSaveTextEditor(
      context: context,
      title: '编辑 AI 分析提示词',
      initialValue: currentPrompt,
      maxLines: 12,
      onSave: (value) async {
        result = value;
      });
  return result;
}
