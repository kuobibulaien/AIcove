/// AutoReplyDialogs - 自动回复相关对话框
/// 
/// 从 auto_reply_settings_page.dart 提取，处理模型选择和提示词编辑。
/// 
/// 更新记录：
/// - 2025-12-31: 从 auto_reply_settings_page.dart 提取，改用底部弹窗
library;

import 'package:flutter/material.dart';

import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/index.dart';
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
  availableModels.add(ModelOption(
    model: null,
    provider: null,
    displayName: '使用默认对话模型',
    subtitle: settings.defaultModelName,
  ));
  
  // 从 providers 中提取所有可用模型
  for (final provider in settings.providers) {
    for (final model in provider.models) {
      availableModels.add(ModelOption(
        model: model,
        provider: provider.id,
        displayName: model,
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
        final isSelected = option.model == draft.analyzerModel;
        final colors = context.moeColors;
        
        return ListTile(
          leading: Icon(
            isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
            color: isSelected ? colors.primary : colors.muted,
          ),
          title: Text(option.displayName),
          subtitle: Text(option.subtitle, style: TextStyle(color: colors.muted)),
          onTap: () => Navigator.pop(context, option),
        );
      },
    ),
  );
}

/// 显示编辑提示词底部弹窗
Future<String?> showEditPromptSheet({
  required BuildContext context,
  required String currentPrompt,
}) async {
  final controller = TextEditingController(text: currentPrompt);

  final result = await showMoeBottomSheet<String>(
    context: context,
    title: '编辑 AI 分析提示词',
    showCloseButton: true,
    maxHeight: MediaQuery.of(context).size.height * 0.9,
    builder: (context) {
      final colors = context.moeColors;
      return Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Column(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: InputDecoration(
                  hintText: '请输入提示词...',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  contentPadding: const EdgeInsets.all(12),
                ),
                style: TextStyle(
                  fontSize: 13,
                  fontFamily: 'monospace',
                  color: colors.text,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: MoeSecondaryButton(
                    label: '取消',
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: MoePrimaryButton(
                    label: '保存',
                    onPressed: () => Navigator.pop(context, controller.text),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );

  controller.dispose();
  return result;
}
