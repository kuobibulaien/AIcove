/// ModelRowTile - 模型行组件
/// 
/// 从 model_list_page.dart 提取，显示单个模型的信息。
/// 
/// 设计特点：
/// - 显示模型ID和备注名
/// - 支持编辑备注
/// - 支持切换可见性
/// 
/// 更新记录：
/// - 2025-12-31: 从 model_list_page.dart 提取
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/settings/app_settings.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/index.dart';

/// 模型行组件（用于已显示模型列表）
class ModelRowTile extends ConsumerWidget {
  final String providerId;
  final String model;
  final String? displayName;
  final bool canHide;
  final bool providerEnabled;

  const ModelRowTile({
    super.key,
    required this.providerId,
    required this.model,
    required this.displayName,
    required this.canHide,
    required this.providerEnabled,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(appSettingsProvider.notifier);
    final colors = context.moeColors;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.borderLight, width: borderWidth),
      ),
      child: Row(
        children: [
          // 模型信息
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  model,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: colors.text,
                  ),
                ),
                if (displayName != null && displayName!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    displayName!,
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.muted,
                    ),
                  ),
                ],
              ],
            ),
          ),
          // 编辑按钮
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 18),
            color: colors.muted,
            tooltip: '编辑备注',
            onPressed: () => _showEditModelNameDialog(
              context: context,
              ref: ref,
              modelId: model,
              currentDisplayName: displayName,
            ),
          ),
          // 可见性切换
          Switch(
            value: true, // 已显示模型始终为true
            onChanged: (canHide && providerEnabled)
                ? (value) {
                    if (!value) {
                      notifier.setModelVisibility(
                        providerId: providerId,
                        modelId: model,
                        visible: false,
                      );
                    }
                  }
                : null,
          ),
        ],
      ),
    );
  }

  /// 显示编辑模型备注弹窗
  Future<void> _showEditModelNameDialog({
    required BuildContext context,
    required WidgetRef ref,
    required String modelId,
    String? currentDisplayName,
  }) async {
    final ctrl = TextEditingController(text: currentDisplayName ?? '');
    final formKey = GlobalKey<FormState>();

    final confirmed = await showMoeBottomSheet<bool>(
      context: context,
      title: '编辑模型备注',
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '模型ID: $modelId',
                style: TextStyle(
                  fontSize: 12,
                  color: context.moeColors.muted,
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: ctrl,
                decoration: const InputDecoration(
                  labelText: '显示名称（备注）',
                  hintText: '留空则显示原始ID',
                  border: OutlineInputBorder(),
                ),
                autofocus: true,
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  MoeSecondaryButton(
                    label: '取消',
                    onPressed: () => Navigator.pop(context, false),
                  ),
                  const SizedBox(width: 12),
                  MoePrimaryButton(
                    label: '保存',
                    onPressed: () => Navigator.pop(context, true),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (confirmed == true) {
      try {
        await ref.read(appSettingsProvider.notifier).setModelDisplayName(
              modelId: modelId,
              displayName: ctrl.text.trim().isEmpty ? null : ctrl.text.trim(),
            );
        if (!context.mounted) return;
        MoeToast.success(context, '备注已保存');
      } catch (e) {
        if (!context.mounted) return;
        MoeToast.error(context, '保存失败: $e');
      }
    }
  }
}
