/// ModelRowTile - 模型行组件
///
/// 从 model_list_page.dart 提取，显示单个模型的信息。
///
/// 设计特点：
/// - 显示模型ID和备注名
/// - 支持编辑备注和类型
/// - 支持切换可见性
/// - 显示模型特性标签和类型标签
/// - 支持复制模型原始ID
///
/// 更新记录：
/// - 2026-01-27: 添加模型类型标签、复制按钮、类型编辑功能
/// - 2026-01-25: 添加模型特性标签显示（视觉/工具/思考/联网）
/// - 2025-12-31: 从 model_list_page.dart 提取
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/settings/app_settings.dart';
import '../../../../features/settings/settings_models.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/shared/widgets/provider/capability_chips.dart';

/// 模型行组件（用于已显示模型列表）
class ModelRowTile extends ConsumerWidget {
  final String providerId;
  final String model;
  final String? displayName;

  const ModelRowTile({
    super.key,
    required this.providerId,
    required this.model,
    required this.displayName,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;
    final cs = Theme.of(context).colorScheme;
    final features = inferModelFeatures(model);
    final hasDisplayName = displayName != null && displayName!.isNotEmpty;

    // 获取模型类型和配置
    final settings = ref.watch(appSettingsProvider).valueOrNull;
    final modelType = settings?.getModelType(model) ?? ModelType.chat;
    final modelConfig = settings?.getModelConfig(model) ?? const ModelConfig();

    return MoeSettingsRow(
      label: hasDisplayName ? displayName! : model,
      labelMaxLines: 1,
      subtitleWidget: _buildSubtitle(colors, hasDisplayName, features.isNotEmpty, modelType),
      trailingType: MoeSettingsRowTrailing.custom,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 复制模型ID按钮
          MoeIconButton(
            icon: Icons.copy_outlined,
            size: 16,
            padding: const EdgeInsets.all(6),
            minTouchTarget: 32,
            color: colors.muted,
            onTap: () => _copyModelId(context, model),
          ),
          const SizedBox(width: 2),
          MoeIconButton(
            icon: Icons.edit_outlined,
            size: 18,
            padding: const EdgeInsets.all(6),
            minTouchTarget: 32,
            color: colors.muted,
            onTap: () => _showEditModelDialog(
              context: context,
              ref: ref,
              modelId: model,
              currentDisplayName: displayName,
              currentType: modelType,
              currentConfig: modelConfig,
            ),
          ),
          const SizedBox(width: 2),
          MoeIconButton(
            icon: Icons.delete_outline,
            size: 18,
            padding: const EdgeInsets.all(6),
            minTouchTarget: 32,
            color: cs.error,
            onTap: () => _confirmDeleteModel(
              context: context,
              ref: ref,
              providerId: providerId,
              modelId: model,
              displayName: displayName,
            ),
          ),
        ],
      ),
      onTap: () => _showEditModelDialog(
        context: context,
        ref: ref,
        modelId: model,
        currentDisplayName: displayName,
        currentType: modelType,
        currentConfig: modelConfig,
      ),
      onLongPress: () => _copyModelId(context, model),
    );
  }

  /// 复制模型ID（原始名称）
  void _copyModelId(BuildContext context, String modelId) {
    Clipboard.setData(ClipboardData(text: modelId));
    HapticFeedback.mediumImpact();
    MoeToast.brief(context, '已复制: $modelId');
  }

  /// 构建副标题区域（模型ID + 类型标签 + 特性标签）
  Widget? _buildSubtitle(MoeColors colors, bool hasDisplayName, bool hasFeatures, ModelType modelType) {
    // chat 类型不显示标签（默认类型）
    final showTypeTag = modelType != ModelType.chat;

    if (!hasDisplayName && !hasFeatures && !showTypeTag) return null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 第一行：模型ID（如果有备注名）
        if (hasDisplayName)
          Text(
            model,
            style: TextStyle(fontSize: 12, color: colors.muted),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        // 第二行：类型标签 + 特性标签
        if (showTypeTag || hasFeatures)
          Padding(
            padding: EdgeInsets.only(top: hasDisplayName ? 4 : 0),
            child: Row(
              children: [
                // 模型类型标签（非 chat 类型才显示）
                if (showTypeTag) ...[
                  _ModelTypeChip(type: modelType),
                  if (hasFeatures) const SizedBox(width: 4),
                ],
                // 模型特性标签
                if (hasFeatures)
                  ModelFeatureChips(modelId: model, maxShow: 2),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _confirmDeleteModel({
    required BuildContext context,
    required WidgetRef ref,
    required String providerId,
    required String modelId,
    String? displayName,
  }) async {
    final label = (displayName != null && displayName.isNotEmpty)
        ? '「$displayName」($modelId)'
        : '「$modelId」';

    final confirmed = await showMeoTalkDialog(
      context: context,
      title: '删除模型',
      content: Text('确定要从该渠道中删除 $label 吗？'),
      confirmText: '删除',
      cancelText: '取消',
    );

    if (confirmed != true) return;

    try {
      await ref.read(appSettingsProvider.notifier).deleteProviderModel(
            providerId: providerId,
            modelId: modelId,
          );
      if (!context.mounted) return;
      MoeToast.success(context, '已删除模型');
    } catch (e) {
      if (!context.mounted) return;
      MoeToast.error(context, '删除失败: $e');
    }
  }

  /// 显示编辑模型弹窗（支持修改备注、类型、工具调用、模型参数）
  Future<void> _showEditModelDialog({
    required BuildContext context,
    required WidgetRef ref,
    required String modelId,
    String? currentDisplayName,
    required ModelType currentType,
    required ModelConfig currentConfig,
  }) async {
    final ctrl = TextEditingController(text: currentDisplayName ?? '');
    final tempCtrl = TextEditingController(
      text: currentConfig.temperature?.toStringAsFixed(1) ?? '',
    );
    final topPCtrl = TextEditingController(
      text: currentConfig.topP?.toStringAsFixed(2) ?? '',
    );
    final ctxLimitCtrl = TextEditingController(
      text: currentConfig.contextMessageLimit?.toString() ?? '',
    );
    var selectedType = currentType;
    var disableToolCalling = currentConfig.disableToolCalling;

    final confirmed = await showMoeBottomSheet<bool>(
      context: context,
      title: '编辑模型',
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 模型ID（带复制按钮）
                Row(
                  children: [
                    Text(
                      '模型ID: ',
                      style: TextStyle(
                        fontSize: 12,
                        color: context.moeColors.muted,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        modelId,
                        style: TextStyle(
                          fontSize: 12,
                          color: context.moeColors.text,
                          fontFamily: 'monospace',
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    MoeIconButton(
                      icon: Icons.copy_outlined,
                      size: 14,
                      color: context.moeColors.muted,
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: modelId));
                        HapticFeedback.lightImpact();
                        MoeToast.brief(context, '已复制');
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // 显示名称输入
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

                // 模型类型选择
                Text(
                  '模型类型',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: MoeFontWeights.emphasis,
                    color: context.moeColors.text,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: ModelType.values.map((type) {
                    final isSelected = type == selectedType;
                    return GestureDetector(
                      onTap: () {
                        setSheetState(() => selectedType = type);
                        HapticFeedback.selectionClick();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? type.color.withValues(alpha: 0.15)
                              : context.moeColors.componentBackground,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isSelected ? type.color : context.moeColors.border,
                            width: isSelected ? 1.5 : 1,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              type.icon,
                              size: 16,
                              color: isSelected ? type.color : context.moeColors.muted,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              type.label,
                              style: TextStyle(
                                fontSize: 13,
                                color: isSelected ? type.color : context.moeColors.text,
                                fontWeight: isSelected ? MoeFontWeights.emphasis : MoeFontWeights.normal,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),

                // 模型参数
                const SizedBox(height: 16),
                Text(
                  '模型参数',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: MoeFontWeights.emphasis,
                    color: context.moeColors.text,
                  ),
                ),
                Text(
                  '为空时使用全局默认值',
                  style: TextStyle(
                    fontSize: 11,
                    color: context.moeColors.muted,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: tempCtrl,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: InputDecoration(
                          labelText: '温度',
                          hintText: '默认',
                          hintStyle: TextStyle(color: context.moeColors.muted),
                          border: const OutlineInputBorder(),
                          helperText: '0~2',
                          helperStyle: TextStyle(fontSize: 10, color: context.moeColors.muted),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextFormField(
                        controller: topPCtrl,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: InputDecoration(
                          labelText: 'Top P',
                          hintText: '关闭',
                          hintStyle: TextStyle(color: context.moeColors.muted),
                          border: const OutlineInputBorder(),
                          helperText: '0~1',
                          helperStyle: TextStyle(fontSize: 10, color: context.moeColors.muted),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextFormField(
                        controller: ctxLimitCtrl,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: '上下文数',
                          hintText: '自动',
                          hintStyle: TextStyle(color: context.moeColors.muted),
                          border: const OutlineInputBorder(),
                          helperText: '消息条数',
                          helperStyle: TextStyle(fontSize: 10, color: context.moeColors.muted),
                        ),
                      ),
                    ),
                  ],
                ),

                // 禁用工具调用开关
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: context.moeColors.componentBackground,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: context.moeColors.border),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.build_outlined,
                        size: 18,
                        color: context.moeColors.muted,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '禁用工具调用',
                              style: TextStyle(
                                fontSize: 14,
                                color: context.moeColors.text,
                              ),
                            ),
                            Text(
                              '开启后 AI 无法使用语音、提醒等插件',
                              style: TextStyle(
                                fontSize: 11,
                                color: context.moeColors.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Switch(
                        value: disableToolCalling,
                        onChanged: (value) {
                          setSheetState(() => disableToolCalling = value);
                          HapticFeedback.selectionClick();
                        },
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 20),
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
      ),
    );

    if (confirmed == true) {
      try {
        final notifier = ref.read(appSettingsProvider.notifier);

        // 保存显示名称
        await notifier.setModelDisplayName(
          modelId: modelId,
          displayName: ctrl.text.trim().isEmpty ? null : ctrl.text.trim(),
        );

        // 保存模型类型
        await notifier.setModelType(
          modelId: modelId,
          type: selectedType,
        );

        // 解析参数值
        final tempText = tempCtrl.text.trim();
        final topPText = topPCtrl.text.trim();
        final ctxText = ctxLimitCtrl.text.trim();

        // 保存模型配置（包括工具调用、温度、TopP、上下文数）
        await notifier.updateModelConfig(
          modelId: modelId,
          disableToolCalling: disableToolCalling,
          temperature: tempText.isNotEmpty ? double.tryParse(tempText) : null,
          clearTemperature: tempText.isEmpty,
          topP: topPText.isNotEmpty ? double.tryParse(topPText) : null,
          clearTopP: topPText.isEmpty,
          contextMessageLimit: ctxText.isNotEmpty ? int.tryParse(ctxText) : null,
          clearContextMessageLimit: ctxText.isEmpty,
        );

        if (!context.mounted) return;
        MoeToast.success(context, '已保存');
      } catch (e) {
        if (!context.mounted) return;
        MoeToast.error(context, '保存失败: $e');
      }
    }
  }
}

/// 模型类型标签组件
class _ModelTypeChip extends StatelessWidget {
  const _ModelTypeChip({required this.type});

  final ModelType type;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = type.color.withValues(alpha: isDark ? 0.2 : 0.12);
    final fgColor = isDark ? type.color.withValues(alpha: 0.9) : type.color;

    return Container(
      height: 16,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(type.icon, size: 10, color: fgColor),
          const SizedBox(width: 3),
          Text(
            type.label,
            style: TextStyle(
              fontSize: 10,
              color: fgColor,
              fontWeight: MoeFontWeights.emphasis,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}
