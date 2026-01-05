/// 模型选择器弹窗组件
/// 
/// 从 composer.dart 提取，用于选择 AI 模型。
/// 
/// 更新记录：
/// - 2025-12-31: 从 composer.dart 提取
library;

import 'package:flutter/material.dart';
import '../../../../../ui/theme/tokens.dart';

/// 模型选择器弹窗
class ModelSelectorSheet extends StatelessWidget {
  final List<String> models;
  final String currentModel;
  final ValueChanged<String> onSelectModel;
  final String Function(String) getDisplayName;

  const ModelSelectorSheet({
    super.key,
    required this.models,
    required this.currentModel,
    required this.onSelectModel,
    required this.getDisplayName,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final sheetBgColor = isDark ? colors.surface : Colors.white;

    return Container(
      decoration: BoxDecoration(
        color: sheetBgColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 顶部拖动指示器
            Container(
              margin: const EdgeInsets.only(top: 8, bottom: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: colors.muted.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // 标题
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '选择AI模型',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: colors.text,
                ),
              ),
            ),
            Divider(height: 1, color: colors.border),
            // 模型列表
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: models.length,
                itemBuilder: (context, index) {
                  final model = models[index];
                  final displayName = getDisplayName(model);
                  final isSelected = model == currentModel;

                  return Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => onSelectModel(model),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        decoration: BoxDecoration(
                          color: isSelected ? colors.surface : Colors.transparent,
                          border: Border(
                            bottom: BorderSide(
                              color: colors.borderLight,
                              width: index < models.length - 1 ? 1 : 0,
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                displayName,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: colors.text,
                                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                                ),
                              ),
                            ),
                            if (isSelected)
                              Icon(
                                Icons.check_circle,
                                color: colors.primary,
                                size: 20,
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
